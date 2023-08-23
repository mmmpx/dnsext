{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}

-- | Fast stream implementaion.
--
-- * Spec: https://github.com/farsightsec/fstrm/blob/master/fstrm/control.h

module DNS.TAP.FastStream (
    -- * Types
    Config (..),
    Context,
    newContext,
    -- * Reader and writer
    reader,
    -- * API
    handshake,
    recvData,
    sendData,
    bye,
) where

import UnliftIO.Exception as E
import Control.Monad
import qualified Data.ByteString.Char8 as C8
import Data.Word
import Network.ByteOrder
import Network.Socket
import qualified Network.Socket.BufferPool as P
import qualified Network.Socket.ByteString as NSB

----------------------------------------------------------------

-- | Configuration for fast stream.
data Config = Config
    { bidirectional :: Bool
    , isReader :: Bool
    , debug :: Bool
    }

----------------------------------------------------------------

-- | Context of a connection.
data Context = Context
    { ctxRecv :: Int -> IO ByteString
    , ctxSend :: [ByteString] -> IO ()
    , ctxBidi :: Bool
    , ctxReader :: Bool
    , ctxDebug :: Bool
    }

-- | Creating 'Context' from 'Socket'.
newContext :: Socket -> Config -> IO Context
newContext s conf = do
    pool <- P.newBufferPool 512 16384
    recvN <- P.makeRecvN "" $ P.receive s pool
    return
        Context
            { ctxRecv = recvN
            , ctxSend = NSB.sendMany s
            , ctxBidi = bidirectional conf
            , ctxReader = isReader conf
            , ctxDebug = debug conf
            }

----------------------------------------------------------------

data Control = Control {fromControl :: Word32} deriving (Eq)

{- FOURMOLU_DISABLE -}
pattern ESCAPE :: Control
pattern ESCAPE  = Control 0x00
pattern ACCEPT :: Control
pattern ACCEPT  = Control 0x01
pattern START  :: Control
pattern START   = Control 0x02
pattern STOP   :: Control
pattern STOP    = Control 0x03
pattern READY  :: Control
pattern READY   = Control 0x04
pattern FINISH :: Control
pattern FINISH  = Control 0x05

instance Show Control where
    show ESCAPE = "ESCAPE"
    show ACCEPT = "ACCEPT"
    show START  = "START"
    show STOP   = "STOP"
    show READY  = "READY"
    show FINISH = "FINISH"
    show (Control n) = "Control " ++ show n
{- FOURMOLU_ENABLE -}

----------------------------------------------------------------

data FieldType = FieldType {fromFieldType :: Word32} deriving (Eq, Show)

pattern ContentType :: FieldType
pattern ContentType = FieldType 0x01

----------------------------------------------------------------

data FSException = FSException String deriving (Show, Typeable)

instance Exception FSException

----------------------------------------------------------------

recvLength :: Context -> IO Word32
recvLength Context{..} = do
    bsc <- ctxRecv 4
    unsafeWithByteString bsc peek32

recvControl :: Context -> IO Control
recvControl Context{..} = do
    bsc <- ctxRecv 4
    Control <$> unsafeWithByteString bsc peek32

recvContent :: Context -> Word32 -> IO ByteString
recvContent Context{..} l = ctxRecv $ fromIntegral l

----------------------------------------------------------------

-- ESCAPE is already received.
recvControlFrame :: Context -> Control -> IO [(FieldType,ByteString)]
recvControlFrame ctx@Context{..} ctrl = do
    l0 <- recvLength ctx
    when (l0 < 4) $ throwIO $ FSException "illegal control length"
    c <- recvControl ctx
    check c ctrl
    when ctxDebug $ print ctrl
    let l1 = l0 - 4
    loop l1 id
  where
    loop 0 build = return $ build []
    loop l build = do
        when (l < 8) $ throwIO $ FSException "illegal field length"
        ft <- FieldType <$> recvLength ctx
        l0 <- recvLength ctx
        ct <- recvContent ctx l0
        if ft == ContentType
            then do
                when ctxDebug $ do
                    putStr "Content-Type: "
                    C8.putStrLn ct
            else when ctxDebug $ putStrLn "unknown field"
        loop (l - 8 - l0) (build . ((ft,ct) :))

check :: Control -> Control -> IO ()
check c ctrl = when (c /= ctrl) $ throwIO $ FSException ("no " ++ show ctrl)

sendControlFrame :: Context -> Control -> [(FieldType,ByteString)] -> IO ()
sendControlFrame Context{..} ctrl xs = do
    let esc = bytestring32 $ fromControl ESCAPE
        ctr = bytestring32 $ fromControl ctrl
        xss = concatMap enc xs
        len = bytestring32 $ fromIntegral (4 + sum (map C8.length xss))
    ctxSend (esc : len : ctr : xss)
  where
    enc (t,c) = [ bytestring32 $ fromFieldType t
                , bytestring32 $ fromIntegral $ C8.length c
                , c
                ]

----------------------------------------------------------------
-- API

-- | Setting up the connection.
handshake :: Context -> IO ()
handshake ctx@Context{..}
    | ctxReader = do
        when ctxBidi $ do
            c <- recvControl ctx
            check c ESCAPE
            ct <- recvControlFrame ctx READY
            -- fixme: select one
            sendControlFrame ctx ACCEPT ct
        c <- recvControl ctx
        print c
        check c ESCAPE
        void $ recvControlFrame ctx START
    | otherwise = sendControlFrame ctx START []

-- | Receiving data.
--   "" indicates that writer stops writing.
recvData :: Context -> IO ByteString
recvData ctx@Context{..}
    | ctxReader = do
        l <- recvLength ctx
        when ctxDebug $ putStrLn "--------------------------------"
        if l == 0
            then return ""
            else do
                when ctxDebug $ putStrLn $ "fstrm data length: " ++ show l
                bs <- recvContent ctx l
                return bs
    | otherwise = throwIO $ FSException "client cannot use recvData"

-- | Writing data.
sendData :: Context -> ByteString -> IO ()
sendData Context{..} _bs
    | ctxReader = throwIO $ FSException "server cannot use sendData"
    | otherwise = undefined

-- | Tearing down the connection.
bye :: Context -> IO ()
bye ctx@Context{..}
    | ctxReader = do
        void $ recvControlFrame ctx STOP
        when ctxBidi $ sendControlFrame ctx FINISH [] `E.catch` \(E.SomeException _) -> return ()
    | otherwise = do
        sendControlFrame ctx STOP []
        when ctxBidi $ void $ recvControlFrame ctx FINISH

----------------------------------------------------------------

-- | Reading loop.
reader :: Context -> (ByteString -> IO ()) -> IO ()
reader ctx body = do
    handshake ctx
    loop
    bye ctx
  where
    loop = do
        bs <- recvData ctx
        if C8.length bs == 0
            then return ()
            else do
                body bs
                loop
