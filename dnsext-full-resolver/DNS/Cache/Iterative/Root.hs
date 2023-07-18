{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module DNS.Cache.Iterative.Root (
    refreshRoot,
    rootPriming,
    cachedDNSKEY,
    takeDEntryIPs,
    rootHint,
) where

-- GHC packages
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT, throwE)
import Control.Monad.Trans.Reader (asks)
import Data.IORef (atomicWriteIORef, readIORef)
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set

-- other packages
import System.Console.ANSI.Types

-- dns packages
import DNS.Do53.Memo (
    rankedAdditional,
    rankedAnswer,
 )
import DNS.SEC (
    RD_DNSKEY,
    RD_DS (..),
    RD_RRSIG (..),
    TYPE (DNSKEY),
 )
import qualified DNS.SEC.Verify as SEC
import DNS.Types (
    Domain,
    ResourceRecord (..),
    TTL,
    TYPE (NS),
 )
import qualified DNS.Types as DNS
import Data.IP (IP (IPv4, IPv6))

-- this package
import DNS.Cache.Iterative.Cache
import DNS.Cache.Iterative.Helpers
import DNS.Cache.Iterative.Norec
import DNS.Cache.Iterative.Random
import DNS.Cache.Iterative.Types
import DNS.Cache.Iterative.Utils
import DNS.Cache.Iterative.Verify
import DNS.Cache.RootServers (rootServers)
import DNS.Cache.RootTrustAnchors (rootSepDS)
import DNS.Cache.Types (NE)
import qualified DNS.Log as Log

refreshRoot :: DNSQuery Delegation
refreshRoot = do
    curRef <- lift $ asks currentRoot_
    let refresh = do
            n <- getRoot
            liftIO $ atomicWriteIORef curRef $ Just n
            return n
        keep = do
            current <- liftIO $ readIORef curRef
            maybe refresh return current
        checkLife = do
            nsc <- lift $ lookupCache "." NS
            maybe refresh (const keep) nsc
    checkLife
  where
    getRoot = do
        let fallback s = lift $ do
                {- fallback to rootHint -}
                logLn Log.WARN $ "refreshRoot: " ++ s
                return rootHint
        either fallback return =<< rootPriming

{-
steps of root priming
1. get DNSKEY RRset of root-domain using `cachedDNSKEY` steps
2. query NS from root-domain with DO flag - get NS RRset and RRSIG
3. verify NS RRset of root-domain with RRSIGa
 -}
rootPriming :: DNSQuery (Either String Delegation)
rootPriming = do
    disableV6NS <- lift $ asks disableV6NS_
    ips <- selectIPs 4 $ takeDEntryIPs disableV6NS hintDes
    lift . logLn Log.DEMO . unwords $ "root-server addresses for priming:" : [show ip | ip <- ips]
    body ips
  where
    throw s = throwE $ "rootPriming: " ++ s
    liftCXT = lift . lift
    logResult delegationNS color s = liftCXT $ do
        clogLn Log.DEMO (Just color) $ "root-priming: " ++ s
        logLn Log.DEMO $ ppDelegation delegationNS
    body ips = runExceptT $ do
        dnskeys <- either throw pure =<< lift (cachedDNSKEY [rootSepDS] ips ".")
        msgNS <- lift $ norec True ips "." NS

        (nsps, nsSet, cacheNS, nsGoodSigs) <- withSection rankedAnswer msgNS $ \rrs rank -> do
            let nsps = nsList "." (,) rrs
                (nss, nsRRs) = unzip nsps
                rrsigs = rrsigList "." NS rrs
            (rs, cacheNS) <- liftCXT $ verifyAndCache dnskeys nsRRs rrsigs rank
            pure (nsps, Set.fromList nss, cacheNS, rrsetGoodSigs rs)
        let (axRRs, cacheAX) = withSection rankedAdditional msgNS $ \rrs rank ->
                (axList False (`Set.member` nsSet) (\_ x -> x) rrs, cacheSection axRRs rank)

        Delegation{..} <- maybe (throw "no delegation") pure $ takeDelegationSrc nsps [rootSepDS] axRRs
        when (null nsGoodSigs) $ do
            logResult delegationNS Red "verification failed - RRSIG of NS: \".\""
            throw "DNSSEC verification failed"

        liftCXT $ do
            cacheNS
            cacheAX
        logResult delegationNS Green "verification success - RRSIG of NS: \".\""
        pure $ Delegation delegationZone delegationNS delegationDS dnskeys

    Delegation _dot hintDes _ _ = rootHint

{-
steps to get verified and cached DNSKEY RRset
1. query DNSKEY from delegatee with DO flag - get DNSKEY RRset and its RRSIG
2. verify SEP DNSKEY of delegatee with DS
3. verify DNSKEY RRset of delegatee with RRSIG
4. cache DNSKEY RRset with RRSIG when validation passes
 -}
cachedDNSKEY :: [RD_DS] -> [IP] -> Domain -> DNSQuery (Either String [RD_DNSKEY])
cachedDNSKEY [] _ _ = return $ Left "cachedDSNKEY: no DS entry"
cachedDNSKEY dss aservers dom = do
    msg <- norec True aservers dom DNSKEY
    let rcode = DNS.rcode $ DNS.flags $ DNS.header msg
    lift $ case rcode of
        DNS.NoErr -> withSection rankedAnswer msg $ \rrs rank ->
            either (return . Left) (doCache rank) $ verifySEP dss dom rrs
        _ -> return $ Left $ "cachedDNSKEY: error rcode to get DNSKEY: " ++ show rcode
  where
    doCache rank (seps, dnskeys, rrsigs) = do
        (rrset, cacheDNSKEY) <-
            verifyAndCache (map fst seps) (map snd dnskeys) rrsigs rank
        if rrsetValid rrset {- only cache DNSKEY RRset on verification successs -}
            then cacheDNSKEY *> return (Right $ map fst dnskeys)
            else return $ Left "cachedDNSKEY: no verified RRSIG found"

verifySEP
    :: [RD_DS]
    -> Domain
    -> [ResourceRecord]
    -> Either String ([(RD_DNSKEY, RD_DS)], [(RD_DNSKEY, ResourceRecord)], [(RD_RRSIG, TTL)])
verifySEP dss dom rrs = do
    let rrsigs = rrsigList dom DNSKEY rrs
    when (null rrsigs) $ Left $ verifyError "no RRSIG found for DNSKEY"

    let dnskeys = rrListWith DNSKEY DNS.fromRData dom (,) rrs
        seps =
            [ (key, ds)
            | (key, _) <- dnskeys
            , ds <- dss
            , Right () <- [SEC.verifyDS dom key ds]
            ]
    when (null seps) $ Left $ verifyError "no DNSKEY matches with DS"

    return (seps, dnskeys, rrsigs)
  where
    verifyError s = "verifySEP: " ++ s

-- {-# ANN rootHint ("HLint: ignore Use tuple-section") #-}
rootHint :: Delegation
rootHint =
    fromMaybe
        (error "rootHint: bad configuration.")
        $ takeDelegationSrc (nsList "." (,) ns) [] as
  where
    (ns, as) = rootServers

takeDEntryIPs :: Bool -> NE DEntry -> [IP]
takeDEntryIPs disableV6NS des = unique $ foldr takeDEntryIP [] (fst des : snd des)
  where
    unique = Set.toList . Set.fromList
    takeDEntryIP (DEonlyNS{}) xs = xs
    takeDEntryIP (DEwithAx _ ip@(IPv4{})) xs = ip : xs
    takeDEntryIP (DEwithAx _ ip@(IPv6{})) xs
        | disableV6NS = xs
        | otherwise = ip : xs
