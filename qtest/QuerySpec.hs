module QuerySpec where

import Test.Hspec

import Control.Concurrent (forkIO, threadDelay)
import Data.Either (isRight)
import Data.List (uncons)
import Data.String (fromString)
import Network.DNS (TYPE(NS, A, AAAA, MX, CNAME, PTR))
import qualified Network.DNS as DNS
import System.Environment (lookupEnv)

import qualified DNSC.UpdateCache as UCache
import qualified DNSC.TimeCache as TimeCache
import DNSC.Iterative (newContext, runDNSQuery, replyMessage, replyAnswer, rootNS)
import qualified DNSC.Iterative as Iterative

data AnswerResult
  = Empty
  | NotEmpty
  | Failed
  deriving (Eq, Show)

spec :: Spec
spec = describe "query" $ do
  disableV6NS <- runIO $ maybe False ((== "1") . take 1) <$> lookupEnv "DISABLE_V6_NS"
  tcache <- runIO TimeCache.new
  (loops, ucache, _) <- runIO $ UCache.new (\_ _ -> pure ()) tcache $ 2 * 1024 * 1024
  runIO $ mapM_ forkIO loops
  cxt <- runIO $ newContext (\_ _ -> pure ()) disableV6NS ucache tcache
  cxt4 <- runIO $ newContext (\_ _ -> pure ()) True ucache tcache
  let runIterative = Iterative.runIterative cxt
      runJust = Iterative.runResolveJust cxt
      runResolve n ty = (snd  <$>) <$> Iterative.runResolve cxt n ty
      getReply n ty ident = do
        e <- runDNSQuery (replyAnswer n ty True) cxt
        return $ replyMessage e ident [DNS.Question (fromString n) ty]

  let printQueryError :: Show e => Either e a -> IO ()
      printQueryError = either (putStrLn . ("    QueryError: " ++) . show) (const $ pure ())

      checkAnswer msg
        | null (DNS.answer msg)  =  Empty
        | otherwise              =  NotEmpty
      checkResult = either (const Failed) checkAnswer

  it "rootNS" $ do
    let sp p = case p of (_,_) -> True  -- check not error
    rootNS `shouldSatisfy` sp

  it "iterative" $ do
    result <- runIterative rootNS "iij.ad.jp."
    printQueryError result
    result `shouldSatisfy` isRight

  it "iterative - long" $ do
    result <- runIterative rootNS "c.b.a.pt.dns-oarc.net."
    printQueryError result
    result `shouldSatisfy` isRight

  it "resolve-just - ns" $ do
    result <- runJust "iij.ad.jp." NS
    printQueryError result
    checkResult result `shouldBe` NotEmpty

  it "resolve-just - a" $ do
    result <- runJust "iij.ad.jp." A
    printQueryError result
    checkResult result `shouldBe` NotEmpty

  it "resolve-just - aaaa" $ do
    result <- runJust "iij.ad.jp." AAAA
    printQueryError result
    checkResult result `shouldBe` NotEmpty

  it "resolve-just - mx" $ do
    result <- runJust "iij.ad.jp." MX
    printQueryError result
    checkResult result `shouldBe` NotEmpty

  it "resolve-just - cname" $ do
    result <- runJust "porttest.dns-oarc.net." CNAME
    printQueryError result
    checkResult result `shouldBe` NotEmpty

  it "resolve-just - cname with nx" $ do
    result <- runJust "media-router-aol1.prod.media.yahoo.com." CNAME
    printQueryError result
    checkResult result `shouldBe` NotEmpty

  it "resolve-just - delegation with aa" $ do
    -- `dig -4 @ns1.alibabadns.com. danuoyi.alicdn.com. A` has delegation authority section with aa flag
    result <- Iterative.runResolveJust cxt4 "sc02.alicdn.com.danuoyi.alicdn.com." A
    printQueryError result
    checkResult result `shouldBe` NotEmpty

  it "resolve - cname" $ do
    result <- runResolve "porttest.dns-oarc.net." CNAME
    printQueryError result
    let cached rrs
          | null rrs   =  Empty
          | otherwise  =  NotEmpty
    either (const Failed) (either cached checkAnswer) result `shouldBe` NotEmpty

  it "resolve - a via cname" $ do
    result <- runResolve "clients4.google.com." A
    printQueryError result
    isRight result `shouldBe` True

  it "get-reply - ptr - cache" $ do
    m1 <- getReply "5.0.130.210.in-addr.arpa." PTR 0
    threadDelay $ 2 * 1000 * 1000
    m2 <- getReply "5.0.130.210.in-addr.arpa." PTR 0
    let getTTL = fmap (DNS.rrttl . fst) . uncons . DNS.answer
        t1 = maybe (Left "t1: no RR") return . getTTL =<< m1
        t2 = maybe (Left "t2: no RR") return . getTTL =<< m2
    (>) <$> t1 <*> t2 `shouldBe` Right True

  it "get-reply - a accumulated via cname" $ do
    result <- getReply "media-router-aol1.prod.media.yahoo.com." A 0
    either (const 0) (length . DNS.answer) result `shouldSatisfy` (> 1)
