module DNS.SEC.Verify.Verify where

import Data.Map (Map)
import qualified Data.Map as Map

-- dnsext-types
import DNS.Types

-- this package
import DNS.SEC.PubAlg
import DNS.SEC.Types (RD_RRSIG(..), RD_DNSKEY(..))

import DNS.SEC.Verify.Types (RRSIGImpl, verifyRRSIGwith)
import DNS.SEC.Verify.RSA (rsaSHA1, rsaSHA256, rsaSHA512)
import DNS.SEC.Verify.ECDSA (ecdsaP256SHA, ecdsaP384SHA)
import DNS.SEC.Verify.EdDSA (ed25519, ed448)


rrsigDicts :: Map PubAlg RRSIGImpl
rrsigDicts =
  Map.fromList
  [ (RSASHA1         , rsaSHA1)
  , (RSASHA256       , rsaSHA256)
  , (RSASHA512       , rsaSHA512)
  , (ECDSAP256SHA256 , ecdsaP256SHA)
  , (ECDSAP384SHA384 , ecdsaP384SHA)
  , (ED25519         , ed25519)
  , (ED448           , ed448)
  ]

verifyRRSIG :: RD_DNSKEY -> RD_RRSIG -> ResourceRecord -> Either String ()
verifyRRSIG dnskey rrsig rr =
  maybe (Left $ "verifyRRSIG: unsupported algorithm: " ++ show alg) verify $
  Map.lookup alg rrsigDicts
  where
    alg = dnskey_pubalg dnskey
    verify impl = verifyRRSIGwith impl dnskey rrsig rr
