module DNSC.Iterative (
  -- * query interfaces
  runQuery,
  runQuery1,
  runIterative,
  rootNS, AuthNS,
  printResult,
  traceQuery,

  -- * low-level interfaces
  DNSQuery, runDNSQuery,
  query, query1, iterative,
  ) where

import Control.Concurrent (forkIO, ThreadId)
import Control.Monad (when, void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Control.Monad.Trans.Reader (ReaderT (..), asks)
import qualified Data.ByteString.Char8 as B8
import Data.Ord (comparing)
import Data.Maybe (mapMaybe, listToMaybe)
import Data.List (isSuffixOf, unfoldr, intercalate, uncons, sort, sortOn)
import Data.Bits ((.&.), shiftR)
import Numeric (showHex)
import System.IO (hSetBuffering, stdout, BufferMode (LineBuffering))
import System.Random (randomR, getStdRandom)

import Data.IP (IP (IPv4, IPv6), IPv4, IPv6, fromIPv4, fromIPv6)
import Network.DNS
  (Domain, ResolvConf (..), FlagOp (FlagClear, FlagSet), DNSError, RData (..),
   TYPE(A, NS, AAAA, CNAME, PTR), ResourceRecord (ResourceRecord, rrname, rrtype, rdata), DNSMessage)
import qualified Network.DNS as DNS

import DNSC.RootServers (rootServers)


type Name = String

validate :: Name -> Bool
validate = not . null
-- validate = all (not . null) . splitOn "."

-- nomalize (domain) name to absolute name
normalize :: Name -> Maybe Name
normalize "." = Just "."
normalize s
  -- empty part is not valid, empty name is not valid
  | validate rn   = Just nn
  | otherwise     = Nothing  -- not valid
  where
    (rn, nn) | "." `isSuffixOf` s = (init s, s)
             | otherwise          = (s, s ++ ".")

-- get parent name for valid name
parent :: String -> String
parent n
  | null dotp    =  error "parent: empty name is not valid."
  | dotp == "."  =  "."  -- parent of "." is "."
  | otherwise    =  tail dotp
  where
    dotp = dropWhile (/= '.') n

-- get domain list for normalized name
domains :: Name -> [Name]
domains "."  = []
domains name
  | "." `isSuffixOf` name = name : unfoldr parent_ name
  | otherwise             = error "domains: normalized name is required."
  where
    parent_ n
      | p == "."   =  Nothing
      | otherwise  =  Just (p, p)
      where
        p = parent n

-----

data Context =
  Context
  { trace_ :: Bool
  , disableV6NS_ :: Bool
  }
  deriving Show

data QueryError
  = DnsError DNSError
  | ResponseError String DNSMessage
  deriving Show

type DNSQuery = ExceptT QueryError (ReaderT Context IO)

---

{-
反復検索の概要

目的のドメインに対して、TLD(トップレベルドメイン) から子ドメインの方向へと順に、権威サーバへの A クエリを繰り返す.
権威サーバへの A クエリの返答メッセージには、
authority セクションに、次の権威サーバの名前 (NS) が、
additional セクションにその名前に対するアドレス (A および AAAA) が入っている.
この情報を使って、繰り返し、子ドメインへの検索を行なう.
検索ドメインの初期値はTLD、権威サーバの初期値はルートサーバとなる.
 -}

dnsQueryT :: (Context -> IO (Either QueryError a)) -> DNSQuery a
dnsQueryT = ExceptT . ReaderT

runDNSQuery :: DNSQuery a -> Bool -> Bool -> IO (Either QueryError a)
runDNSQuery q trace disableV6NS = do
  when trace $ hSetBuffering stdout LineBuffering
  runReaderT (runExceptT q) (Context trace disableV6NS)

throwDnsError :: DNSError -> DNSQuery a
throwDnsError = throwE . DnsError

handleResponseError :: (QueryError -> p) -> (DNSMessage -> p) -> DNSMessage -> p
handleResponseError e f msg
  | DNS.qOrR flags /= DNS.QR_Response      =  e $ ResponseError ("Not response code: " ++ show (DNS.qOrR flags)) msg
  | DNS.rcode flags /= DNS.NoErr           =  e $ ResponseError ("Error RCODE: " ++ show (DNS.rcode flags)) msg
  | DNS.ednsHeader msg == DNS.InvalidEDNS  =  e $ ResponseError  "Invalid EDNS header" msg
  | otherwise                              =  f msg
  where
    flags = DNS.flags $ DNS.header msg
-- responseErrEither = handleResponseError Left Right  :: DNSMessage -> Either QueryError DNSMessage
-- responseErrDNSQuery = handleResponseError throwE return  :: DNSMessage -> DNSQuery DNSMessage

withNormalized :: Name -> (Name -> DNSQuery a) -> Bool -> Bool -> IO (Either QueryError a)
withNormalized n action =
  runDNSQuery
  (action =<< maybe (throwDnsError DNS.IllegalDomain) return (normalize n))

runQuery :: Name -> TYPE -> IO (Either QueryError DNSMessage)
runQuery n typ = withNormalized n (`query` typ) False False

traceQuery :: Name -> TYPE -> IO (Either QueryError DNSMessage)
traceQuery n typ = withNormalized n (`query` typ) True False

-- 反復検索を使ったクエリ. 結果が CNAME なら繰り返し解決する.
query :: Name -> TYPE -> DNSQuery DNSMessage
query n typ = do
  msg <- query1 n typ
  let answers = DNS.answer msg

  -- TODO: CNAME 解決の回数制限
  let resolveCNAME cn cnRR = do
        when (any ((== typ) . rrtype) answers) $ throwDnsError DNS.UnexpectedRDATA  -- CNAME と目的の TYPE が同時に存在した場合はエラー
        x <- query (B8.unpack cn) typ
        lift $ cacheRR cnRR
        return x

  maybe
    (pure msg)
    (uncurry resolveCNAME)
    $ listToMaybe $ mapMaybe takeCNAME answers
  where
    takeCNAME rr@ResourceRecord { rrtype = CNAME, rdata = RD_CNAME cn }
      | rrname rr == B8.pack n  =  Just (cn, rr)
    takeCNAME _                 =  Nothing

runQuery1 :: Name -> TYPE -> IO (Either QueryError DNSMessage)
runQuery1 n typ = withNormalized n (`query1` typ) False False

-- 反復検索を使ったクエリ. CNAME は解決しない.
query1 :: Name -> TYPE -> DNSQuery DNSMessage
query1 n typ = do
  lift $ traceLn $ "query1: " ++ show (n, typ)
  nss <- iterative rootNS n
  sa <- selectAuthNS nss
  msg <- dnsQueryT $ const $ norec1 sa (B8.pack n) typ
  lift $ mapM_ cacheRR $ DNS.answer msg
  return msg

runIterative :: AuthNS -> Name -> IO (Either QueryError AuthNS)
runIterative sa n = withNormalized n (iterative sa) False False

type NE a = (a, [a])

-- ドメインに対する複数の NS の情報
type AuthNS = (NE (Domain, ResourceRecord), [ResourceRecord])

{-# ANN rootNS ("HLint: ignore Use fromMaybe") #-}
rootNS :: AuthNS
rootNS =
  maybe
  (error "rootNS: bad configuration.")
  id
  $ uncurry (authorityNS_ (B8.pack ".")) rootServers

-- 反復検索でドメインの NS のアドレスを得る
iterative :: AuthNS -> Name -> DNSQuery AuthNS
iterative sa n = iterative_ sa $ reverse $ domains n

-- 反復検索の本体
iterative_ :: AuthNS -> [Name] -> DNSQuery AuthNS
iterative_ nss []     = return nss
iterative_ nss (x:xs) =
  step nss >>=
  maybe
  (iterative_ nss xs)   -- NS が返らない場合は同じ NS の情報で子ドメインへ. 通常のホスト名もこのケース. ex. or.jp, ad.jp
  (`iterative_` xs)
  where
    name = B8.pack x

    step :: AuthNS -> DNSQuery (Maybe AuthNS)
    step nss_ = do
      sa <- selectAuthNS nss_  -- 親ドメインから同じ NS の情報が引き継がれた場合も、NS のアドレスを選択しなおすことで balancing する.
      lift $ traceLn $ "iterative: " ++ show (sa, name)
      msg <- dnsQueryT $ const $ norec1 sa name A
      let result = authorityNS name msg
      lift $ maybe (pure ()) cacheAuthNS result
      return result

-- 選択可能な NS が有るときだけ Just
authorityNS :: Domain -> DNSMessage -> Maybe AuthNS
authorityNS dom msg = authorityNS_ dom (DNS.authority msg) (DNS.additional msg)

{-# ANN authorityNS_ ("HLint: ignore Use tuple-section") #-}
authorityNS_ :: Domain -> [ResourceRecord] -> [ResourceRecord] -> Maybe AuthNS
authorityNS_ dom auths adds =
  (\x -> (x, adds)) <$> uncons nss
  where
    nss = mapMaybe takeNS auths

    takeNS rr@ResourceRecord { rrtype = NS, rdata = RD_NS ns }
      | rrname rr == dom  =  Just (ns, rr)
    takeNS _              =  Nothing

norec1 :: IP -> Domain -> TYPE -> IO (Either QueryError DNSMessage)
norec1 aserver name typ = do
  rs <- DNS.makeResolvSeed conf
  either (Left . DnsError) (handleResponseError Left Right) <$>
    DNS.withResolver rs ( \resolver -> DNS.lookupRaw resolver name typ )
  where
    conf = DNS.defaultResolvConf
           { resolvInfo = DNS.RCHostName $ show aserver
           , resolvTimeout = 5 * 1000 * 1000
           , resolvRetry = 2
           , resolvQueryControls = DNS.rdFlag FlagClear
           }

-- authority section 内の、Domain に対応する NS レコードが一つも無いときに Nothing
-- そうでなければ、additional section 内の NS の名前に対応する A を利用してアドレスを得る
-- NS の名前に対応する A が無いときには反復検索で解決しに行く (PTR 解決のときには glue レコードが無い)
selectAuthNS :: AuthNS -> DNSQuery IP
selectAuthNS (nss, as) = do
  (ns, nsRR) <- liftIO $ selectNS nss
  disableV6NS <- lift $ asks disableV6NS_

  let takeAx :: ResourceRecord -> Maybe (IP, ResourceRecord)
      takeAx rr@ResourceRecord { rrtype = A, rdata = RD_A ipv4 }
        | rrname rr == ns  =  Just (IPv4 ipv4, rr)
      takeAx rr@ResourceRecord { rrtype = AAAA, rdata = RD_AAAA ipv6 }
        | not disableV6NS &&
          rrname rr == ns  =  Just (IPv6 ipv6, rr)
      takeAx _          =  Nothing

      query1AofNS :: DNSQuery (IP, ResourceRecord)
      query1AofNS =
        maybe (throwDnsError DNS.IllegalDomain) pure  -- 失敗時: NS に対応する A の返答が空
        . listToMaybe . mapMaybe takeAx . DNS.answer
        =<< query1 (B8.unpack ns) A

  (a, aRR) <- maybe query1AofNS return =<< liftIO (selectA $ mapMaybe takeAx as)
  lift $ traceLn $ "selectAuthNS: " ++ show (rrname nsRR, (ns, a))

  when reverseVerify $ do
    -- NS 逆引きの verify は別スレッドに切り離してキャッシュの可否だけに利用する.
    -- たとえば e.in-addr-servers.arpa.  は正引きして逆引きすると  anysec.apnic.net. になって一致しない.
    context <- lift $ asks id
    liftIO $ void $ forkQueryIO (cacheVerifiedNS aRR nsRR) "cacheVerifiedNS: verify query" context  -- verify を別スレッドに切り離す.

  return a

reverseVerify :: Bool
reverseVerify = False

forkQueryIO :: DNSQuery () -> String -> Context -> IO ThreadId
forkQueryIO dq errPrefix context@Context { trace_ = trace } =
  forkIO $
  either (when trace . putStrLn . ((errPrefix ++ ": ") ++) . show) pure =<<
  runReaderT (runExceptT dq) context

cacheVerifiedNS :: ResourceRecord -> ResourceRecord -> DNSQuery ()
cacheVerifiedNS aRR nsRR
  | rrname nsRR == B8.pack "."  =  return ()  -- root は cache しない
  | otherwise   =  do
  good <- verifyA aRR
  lift $ if good
         then do cacheRR nsRR
                 cacheRR aRR
         else    traceLn $ unlines ["cacheVerifiedNS: reverse lookup inconsistent: ", show aRR, show nsRR]

randomSelect :: Bool
randomSelect = True

selectNS :: NE a -> IO a
selectNS rs
  | randomSelect  =  randomizedSelectN rs
  | otherwise     =  return $ fst rs  -- naive implementation

selectA :: [a] -> IO (Maybe a)
selectA as
  | randomSelect  =  randomizedSelect as
  | otherwise     =  do
      -- when (null as) $ putStrLn $ "selectA: warning: zero address list is passed." -- no glue record?
      -- naive implementation
      return $ listToMaybe as

randomizedSelectN :: NE a -> IO a
randomizedSelectN = d
  where
    d (x, []) = return x
    d (x, xs) = do
      ix <- getStdRandom $ randomR (0, length xs)
      return $ (x:xs) !! ix

randomizedSelect :: [a] -> IO (Maybe a)
randomizedSelect = d
  where
    d []   =  return Nothing
    d [x]  =  return $ Just x
    d xs   =  do
      ix <- getStdRandom $ randomR (0, length xs - 1)
      return $ Just $ xs !! ix

v4PtrDomain :: IPv4 -> Name
v4PtrDomain ipv4 = dom
  where
    octets = reverse $ fromIPv4 ipv4
    dom = intercalate "." $ map show octets ++ ["in-addr.arpa."]

v6PtrDomain :: IPv6 -> Name
v6PtrDomain ipv6 = dom
  where
    w16hx w =
      [ (w `shiftR` 12) .&. 0x0f
      , (w `shiftR`  8) .&. 0x0f
      , (w `shiftR`  4) .&. 0x0f
      ,  w              .&. 0x0f
      ]
    hxs = reverse $ concatMap w16hx $ fromIPv6 ipv6
    showH x = showHex x ""
    dom = intercalate "." $ map showH hxs ++ ["ip6.arpa."]

verifyA :: ResourceRecord -> DNSQuery Bool
verifyA aRR@ResourceRecord { rrname = ns } =
  case rdata aRR of
    RD_A ipv4     ->  resolvePTR $ v4PtrDomain ipv4
    RD_AAAA ipv6  ->  resolvePTR $ v6PtrDomain ipv6
    _             ->  return False
  where
    resolvePTR ptrDom = do
      msg <- qSystem ptrDom PTR  -- query が循環しないようにシステムのレゾルバを使う
      let mayPTR = listToMaybe $ mapMaybe takePTR $ DNS.answer msg
      maybe (pure True) checkPTR mayPTR  -- 逆引きが割り当てられていないときは通す

    checkPTR (ptr, ptrRR) = do
      let good =  ptr == ns
      when good $ lift $ do
        cacheRR ptrRR
        traceLn $ "verifyA: verification pass: " ++ show ns
      return good
    takePTR rr@ResourceRecord { rrtype = PTR, rdata = RD_PTR ptr }  =  Just (ptr, rr)
    takePTR _                                                       =  Nothing

    qSystem :: Name -> TYPE -> DNSQuery DNSMessage
    qSystem name typ = dnsQueryT $ const $ do
      rs <- DNS.makeResolvSeed conf
      either (Left . DnsError) (handleResponseError Left Right) <$>
        DNS.withResolver rs ( \resolver -> DNS.lookupRaw resolver (B8.pack name) typ )
        where
          conf = DNS.defaultResolvConf
                 { resolvTimeout = 5 * 1000 * 1000
                 , resolvRetry = 2
                 , resolvQueryControls = DNS.rdFlag FlagSet
                 }

cacheRR :: ResourceRecord -> ReaderT Context IO ()
cacheRR rr = do
  traceLn $ "cacheRR: " ++ show rr

cacheAuthNS :: AuthNS -> ReaderT Context IO ()
cacheAuthNS (nss0@((_, rr), _), as0)
  | rrname rr == B8.pack "."  =  pure ()
  | otherwise                 =
    do cacheNS
       cacheAx
  where
    nss1 = uncurry (:) nss0
    cacheNS = mapM_ (cacheRR . snd) nss1
    as = filter isA as0
    a4s = filter is4A as0
    isA ResourceRecord { rrtype = A, rdata = RD_A {} }  =  True
    isA _                                               =  False
    is4A ResourceRecord { rrtype = AAAA, rdata = RD_AAAA {} }  =  True
    is4A _                                                     =  False
    cacheAx = do
      let nss = map fst nss1
          cacheRRs = mapM_ cacheRR
      mapM_ cacheRRs $ matchAx nss as ++ matchAx nss a4s

matchAx :: [Domain] -> [ResourceRecord] -> [[ResourceRecord]]
matchAx ds0 rs0 =
  filter (not . null)
  $ rec_ id id (sort ds0) (sortOn rrname rs0)
  where
    rec_ res _       []      _        =  res []
    rec_ res as     (_:_)       []    =  res [as []]
    rec_ res as dds@(d:ds) rrs@(r:rs)
      | d < rrname r  =  rec_ (res . (as []:))  id         ds  rrs
      | d > rrname r  =  rec_  res              as         dds rs
      | otherwise     =  rec_  res             (as . (r:)) dds rs

traceLn :: String -> ReaderT Context IO ()
traceLn s = do
  trace <- asks trace_
  when trace $ liftIO $ putStrLn s

printResult :: Either QueryError DNSMessage -> IO ()
printResult = either print pmsg
  where
    pmsg msg =
      putStr $ unlines $
      ["answer:"] ++
      map show (DNS.answer msg) ++
      [""] ++
      ["authority:"] ++
      map show (DNS.authority msg) ++
      [""] ++
      ["additional:"] ++
      map show (DNS.additional msg) ++
      [""]
