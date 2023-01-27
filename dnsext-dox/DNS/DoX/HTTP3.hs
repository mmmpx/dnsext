{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module DNS.DoX.HTTP3 where

import DNS.Do53.Client
import DNS.Do53.Internal
import DNS.Types
import qualified Data.ByteString.Char8 as C8
import Data.ByteString.Short (ShortByteString)
import Network.HTTP3.Client
import Network.QUIC
import qualified Network.QUIC.Client as QUIC
import qualified UnliftIO.Exception as E

import DNS.DoX.Common
import DNS.DoX.HTTP2

http3Resolver :: ShortByteString -> VCLimit -> Resolver
http3Resolver path lim ri@ResolvInfo{..} q qctl = QUIC.run cc $ \conn ->
    E.bracket allocSimpleConfig freeSimpleConfig $ \conf -> do
        ident <- ractionGenId rinfoActions
        h3resolver conn conf ident path lim ri q qctl
  where
    cc = getQUICParams rinfoHostName rinfoPortNumber "h3"

h3resolver :: Connection -> Config -> Identifier -> ShortByteString -> VCLimit -> Resolver
h3resolver conn conf ident path lim ri@ResolvInfo{..} q qctl =
    run conn cliconf conf $ doHTTP ident path lim ri q qctl
  where
    cliconf = ClientConfig {
        scheme = "https"
      , authority = C8.pack rinfoHostName
      }
