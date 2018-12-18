-- |
-- Module: APN
-- Copyright: (C) 2017, memrange UG
-- License: BSD3
-- Maintainer: Hans-Christian Esperer <hc@memrange.io>
-- Stability: experimental
-- Portability: portable
--
-- Send push notifications using Apple's HTTP2 APN API
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TupleSections     #-}

module Network.PushNotify.APN
    ( newSession
    , newMessage
    , newMessageWithCustomPayload
    , hexEncodedToken
    , rawToken
    , sendMessage
    , sendSilentMessage
    , sendRawMessage
    , alertMessage
    , bodyMessage
    , emptyMessage
    , setAlertMessage
    , setMessageBody
    , setBadge
    , setCategory
    , setSound
    , clearAlertMessage
    , clearBadge
    , clearCategory
    , clearSound
    , addSupplementalField
    , closeSession
    , isOpen
    , ApnSession
    , JsonAps
    , JsonApsAlert
    , JsonApsMessage
    , ApnMessageResult(..)
    , ApnFatalError(..)
    , ApnTemporaryError(..)
    , ApnToken
    ) where

import           Control.Concurrent
import           Control.Concurrent.QSem
import           Control.Exception
import           Control.Monad
import           Data.Aeson
import           Data.Aeson.Types
import           Data.ByteString                      (ByteString)
import           Data.Char                            (toLower)
import           Data.Default                         (def)
import           Data.Either
import           Data.Int
import           Data.IORef
import           Data.Map.Strict                      (Map)
import           Data.Maybe
import           Data.Semigroup                       ((<>))
import           Data.Text                            (Text)
import           Data.Time.Clock.POSIX
import           Data.Typeable                        (Typeable)
import           Data.X509
import           Data.X509.CertificateStore
import           GHC.Generics
import           Network.HTTP2                        (ErrorCodeId,
                                                       toErrorCodeId)
import           Network.HTTP2.Client
import           Network.HTTP2.Client.FrameConnection
import           Network.HTTP2.Client.Helpers
import           Network.TLS                          hiding (sendData)
import           Network.TLS.Extra.Cipher
import           System.IO.Error
import           System.Mem.Weak
import           System.Random

import qualified Data.ByteString                      as S
import qualified Data.ByteString.Base16               as B16
import qualified Data.ByteString.Lazy                 as L
import qualified Data.List                            as DL
import qualified Data.Map.Strict                      as M
import qualified Data.Text                            as T
import qualified Data.Text.Encoding                   as TE

import qualified Network.HPACK                        as HTTP2
import qualified Network.HTTP2                        as HTTP2

import           Debug.Trace

-- | A session that manages connections to Apple's push notification service
data ApnSession = ApnSession
    { apnSessionPool              :: !(IORef [ApnConnection])
    , apnSessionConnectionInfo    :: !ApnConnectionInfo
    , apnSessionConnectionManager :: !ThreadId
    , apnSessionOpen              :: !(IORef Bool)}

-- | Information about an APN connection
data ApnConnectionInfo = ApnConnectionInfo
    { aciCertPath             :: !FilePath
    , aciCertKey              :: !FilePath
    , aciCaPath               :: !FilePath
    , aciHostname             :: !Text
    , aciMaxConcurrentStreams :: !Int
    , aciTopic                :: !ByteString }

-- | A connection to an APN API server
data ApnConnection = ApnConnection
    { apnConnectionConnection        :: !Http2Client
    , apnConnectionInfo              :: !ApnConnectionInfo
    , apnConnectionWorkerPool        :: !QSem
    , apnConnectionLastUsed          :: !Int64
    , apnConnectionFlowControlWorker :: !ThreadId
    , apnConnectionOpen              :: !(IORef Bool)}

-- | An APN token used to uniquely identify a device
newtype ApnToken = ApnToken { unApnToken :: ByteString }

class SpecifyError a where
    isAnError :: IOError -> a

-- | Create a token from a raw bytestring
rawToken
    :: ByteString
    -- ^ The bytestring that uniquely identifies a device (APN token)
    -> ApnToken
    -- ^ The resulting token
rawToken = ApnToken . B16.encode

-- | Create a token from a hex encoded text
hexEncodedToken
    :: Text
    -- ^ The base16 (hex) encoded unique identifier for a device (APN token)
    -> ApnToken
    -- ^ The resulting token
hexEncodedToken = ApnToken . B16.encode . fst . B16.decode . TE.encodeUtf8

-- | Exceptional responses to a send request
data ApnException = ApnExceptionHTTP ErrorCodeId
                  | ApnExceptionJSON String
                  | ApnExceptionMissingHeader HTTP2.HeaderName
    deriving (Show, Typeable)

instance Exception ApnException

-- | The result of a send request
data ApnMessageResult = ApnMessageResultOk
                      | ApnMessageResultBackoff
                      | ApnMessageResultFatalError ApnFatalError
                      | ApnMessageResultTemporaryError ApnTemporaryError
                      | ApnMessageResultIOError IOError
    deriving (Eq, Show)

instance SpecifyError ApnMessageResult where
    isAnError = ApnMessageResultIOError

-- | The specification of a push notification's message body
data JsonApsAlert = JsonApsAlert
    { jaaTitle :: !(Maybe Text)
    -- ^ A short string describing the purpose of the notification.
    , jaaBody  :: !Text
    -- ^ The text of the alert message.
    } deriving (Generic, Show)

instance ToJSON JsonApsAlert where
    toJSON     = genericToJSON     defaultOptions
        { fieldLabelModifier = drop 3 . map toLower
        , omitNothingFields  = True
        }

-- | Push notification message's content
data JsonApsMessage
    -- | Push notification message's content
    = JsonApsMessage
    { jamAlert    :: !(Maybe JsonApsAlert)
    -- ^ A text to display in the notification
    , jamBadge    :: !(Maybe Int)
    -- ^ A number to display next to the app's icon. If set to (Just 0), the number is removed.
    , jamSound    :: !(Maybe Text)
    -- ^ A sound to play, that's located in the Library/Sounds directory of the app
    -- This should be the name of a sound file in the application's main bundle, or
    -- in the Library/Sounds directory of the app.
    , jamCategory :: !(Maybe Text)
    -- ^ The category of the notification. Must be registered by the app beforehand.
    } deriving (Generic, Show)

-- | Create an empty apn message
emptyMessage :: JsonApsMessage
emptyMessage = JsonApsMessage Nothing Nothing Nothing Nothing

-- | Set a sound for an APN message
setSound
    :: Text
    -- ^ The sound to use (either "default" or something in the application's bundle)
    -> JsonApsMessage
    -- ^ The message to modify
    -> JsonApsMessage
    -- ^ The modified message
setSound s a = a { jamSound = Just s }

-- | Clear the sound for an APN message
clearSound
    :: JsonApsMessage
    -- ^ The message to modify
    -> JsonApsMessage
    -- ^ The modified message
clearSound a = a { jamSound = Nothing }

-- | Set the category part of an APN message
setCategory
    :: Text
    -- ^ The category to set
    -> JsonApsMessage
    -- ^ The message to modify
    -> JsonApsMessage
    -- ^ The modified message
setCategory c a = a { jamCategory = Just c }

-- | Clear the category part of an APN message
clearCategory
    :: JsonApsMessage
    -- ^ The message to modify
    -> JsonApsMessage
    -- ^ The modified message
clearCategory a = a { jamCategory = Nothing }

-- | Set the badge part of an APN message
setBadge
    :: Int
    -- ^ The badge number to set. The badge number is displayed next to your app's icon. Set to 0 to remove the badge number.
    -> JsonApsMessage
    -- ^ The message to modify
    -> JsonApsMessage
    -- ^ The modified message
setBadge i a = a { jamBadge = Just i }

-- | Clear the badge part of an APN message
clearBadge
    :: JsonApsMessage
    -- ^ The message to modify
    -> JsonApsMessage
    -- ^ The modified message
clearBadge a = a { jamBadge = Nothing }

-- | Create a new APN message with an alert part
alertMessage
    :: Text
    -- ^ The title of the message
    -> Text
    -- ^ The body of the message
    -> JsonApsMessage
    -- ^ The modified message
alertMessage title text = setAlertMessage title text emptyMessage

-- | Create a new APN message with a body and no title
bodyMessage
    :: Text
    -- ^ The body of the message
    -> JsonApsMessage
    -- ^ The modified message
bodyMessage text = setMessageBody text emptyMessage

-- | Set the alert part of an APN message
setAlertMessage
    :: Text
    -- ^ The title of the message
    -> Text
    -- ^ The body of the message
    -> JsonApsMessage
    -- ^ The message to alter
    -> JsonApsMessage
    -- ^ The modified message
setAlertMessage title text a = a { jamAlert = Just jam }
  where
    jam = JsonApsAlert (Just title) text

-- | Set the body of an APN message without affecting the title
setMessageBody
    :: Text
    -- ^ The body of the message
    -> JsonApsMessage
    -- ^ The message to alter
    -> JsonApsMessage
    -- ^ The modified message
setMessageBody text a = a { jamAlert = Just newJaa }
  where
    newJaa = case jamAlert a of
                Nothing  -> JsonApsAlert Nothing text
                Just jaa -> jaa { jaaBody = text }

-- | Remove the alert part of an APN message
clearAlertMessage
    :: JsonApsMessage
    -- ^ The message to modify
    -> JsonApsMessage
    -- ^ The modified message
clearAlertMessage a = a { jamAlert = Nothing }

instance ToJSON JsonApsMessage where
    toJSON     = genericToJSON     defaultOptions
        { fieldLabelModifier = drop 3 . map toLower }

-- | A push notification message
data JsonAps
    -- | A push notification message
    = JsonAps
    { jaAps                :: !JsonApsMessage
    -- ^ The main content of the message
    , jaAppSpecificContent :: !(Maybe Text)
    -- ^ Extra information to be used by the receiving app
    , jaSupplementalFields :: !(Map Text Value)
    -- ^ Additional fields to be used by the receiving app
    } deriving (Generic, Show)

instance ToJSON JsonAps where
    toJSON JsonAps{..} = object (staticFields <> dynamicFields)
        where
            dynamicFields = M.toList jaSupplementalFields
            staticFields = [ "aps" .= jaAps
                           , "appspecificcontent" .= jaAppSpecificContent
                           ]

-- | Prepare a new apn message consisting of a
-- standard message without a custom payload
newMessage
    :: JsonApsMessage
    -- ^ The standard message to include
    -> JsonAps
    -- ^ The resulting APN message
newMessage aps = JsonAps aps Nothing M.empty

-- | Prepare a new apn message consisting of a
-- standard message and a custom payload
newMessageWithCustomPayload
    :: JsonApsMessage
    -- ^ The message
    -> Text
    -- ^ The custom payload
    -> JsonAps
    -- ^ The resulting APN message
newMessageWithCustomPayload message payload =
    JsonAps message (Just payload) M.empty

-- | Add a supplemental field to be sent over with the notification
--
-- NB: The field 'aps' must not be modified; attempting to do so will
-- cause a crash.
addSupplementalField :: ToJSON record =>
       Text
    -- ^ The field name
    -> record
    -- ^ The value
    -> JsonAps
    -- ^ The APN message to modify
    -> JsonAps
    -- ^ The resulting APN message
addSupplementalField "aps"     _          _      = error "The 'aps' field may not be overwritten by user code"
addSupplementalField fieldName fieldValue oldAPN = oldAPN { jaSupplementalFields = newSupplemental }
    where
        oldSupplemental = jaSupplementalFields oldAPN
        newSupplemental = M.insert fieldName (toJSON fieldValue) oldSupplemental

-- | Start a new session for sending APN messages. A session consists of a
-- connection pool of connections to the APN servers, while each connection has a
-- pool of workers that create HTTP2 streams to send individual push
-- notifications.
newSession
    :: FilePath
    -- ^ Path to the client certificate key
    -> FilePath
    -- ^ Path to the client certificate
    -> FilePath
    -- ^ Path to the CA
    -> Bool
    -- ^ True if the apn development servers should be used, False to use the production servers
    -> Int
    -- ^ How many messages will be sent in parallel? This corresponds to the number of http2 streams open in parallel; 100 seems to be a default value.
    -> ByteString
    -- ^ Topic (bundle name of the app)
    -> IO ApnSession
    -- ^ The newly created session
newSession certKey certPath caPath dev maxparallel topic = do
    let hostname = if dev
            then "api.development.push.apple.com"
            else "api.push.apple.com"
        connInfo = ApnConnectionInfo certPath certKey caPath hostname maxparallel topic
    certsOk <- checkCertificates connInfo
    unless certsOk $ error "Unable to load certificates and/or the private key"
    connections <- newIORef []
    connectionManager <- forkIO $ manage 600 connections
    isOpen <- newIORef True
    let session = ApnSession connections connInfo connectionManager isOpen
    addFinalizer session $
        closeSession session
    return session

-- | Manually close a session. The session must not be used anymore
-- after it has been closed. Calling this function will close
-- the worker thread, and all open connections to the APN service
-- that belong to the given session. Note that sessions will be closed
-- automatically when they are garbage collected, so it is not necessary
-- to call this function.
closeSession :: ApnSession -> IO ()
closeSession s = do
    isOpen <- atomicModifyIORef' (apnSessionOpen s) (False,)
    unless isOpen $ error "Session is already closed"
    killThread (apnSessionConnectionManager s)
    let ioref = apnSessionPool s
    openConnections <- atomicModifyIORef' ioref ([],)
    mapM_ closeApnConnection openConnections

-- | Check whether a session is open or has been closed
-- by a call to closeSession
isOpen :: ApnSession -> IO Bool
isOpen = readIORef . apnSessionOpen

withConnection :: ApnSession -> (ApnConnection -> IO a) -> IO a
withConnection s action = do
    ensureOpen s
    let pool = apnSessionPool s
    connections <- readIORef pool
    let len = length connections
    if len == 0
    then do
        conn <- newConnection s
        res <- action conn
        atomicModifyIORef' pool (\a -> (conn:a, ()))
        return res
    else do
        num <- randomRIO (0, len - 1)
        currtime <- round <$> getPOSIXTime :: IO Int64
        let conn = connections !! num
            conn1 = conn { apnConnectionLastUsed=currtime }
        atomicModifyIORef' pool (\a -> (removeNth num a, ()))
        isOpen <- readIORef (apnConnectionOpen conn)
        if isOpen
        then do
            res <- action conn1
            atomicModifyIORef' pool (\a -> (conn1:a, ()))
            return res
        else withConnection s action

checkCertificates :: ApnConnectionInfo -> IO Bool
checkCertificates aci = do
    castore <- readCertificateStore $ aciCaPath aci
    credential <- credentialLoadX509 (aciCertPath aci) (aciCertKey aci)
    return $ isJust castore && isRight credential

replaceNth n newVal (x:xs)
    | n == 0 = newVal:xs
    | otherwise = x:replaceNth (n-1) newVal xs

removeNth n (x:xs)
    | n == 0 = xs
    | otherwise = x:removeNth (n-1) xs

manage :: Int64 -> IORef [ApnConnection] -> IO ()
manage timeout ioref = forever $ do
    currtime <- round <$> getPOSIXTime :: IO Int64
    let minTime = currtime - timeout
    expiredOnes <- atomicModifyIORef' ioref
        (foldl ( \(a,b) i -> if apnConnectionLastUsed i < minTime then (a, i:b ) else ( i:a ,b)) ([],[]))
    mapM_ closeApnConnection expiredOnes
    threadDelay 60000000

newConnection :: ApnSession -> IO ApnConnection
newConnection apnSession = do
    let aci = apnSessionConnectionInfo apnSession
    Just castore <- readCertificateStore $ aciCaPath aci
    Right credential <- credentialLoadX509 (aciCertPath aci) (aciCertKey aci)
    let credentials = Credentials [credential]
        shared      = def { sharedCredentials = credentials
                          , sharedCAStore=castore }
        maxConcurrentStreams = aciMaxConcurrentStreams aci
        clip = ClientParams
            { clientUseMaxFragmentLength=Nothing
            , clientServerIdentification=(T.unpack hostname, undefined)
            , clientUseServerNameIndication=True
            , clientWantSessionResume=Nothing
            , clientShared=shared
            , clientHooks=def
                { onCertificateRequest=const . return . Just $ credential }
            , clientDebug=DebugParams { debugSeed=Nothing, debugPrintSeed=const $ return () }
            , clientSupported=def
                { supportedVersions=[ TLS12 ]
                , supportedCiphers=ciphersuite_strong }
            }

        conf = [ (HTTP2.SettingsMaxFrameSize, 16384)
               , (HTTP2.SettingsMaxConcurrentStreams, maxConcurrentStreams)
               , (HTTP2.SettingsMaxHeaderBlockSize, 4096)
               , (HTTP2.SettingsInitialWindowSize, 65536)
               , (HTTP2.SettingsEnablePush, 1)
               ]

        hostname = aciHostname aci
    httpFrameConnection <- newHttp2FrameConnection (T.unpack hostname) 443 (Just clip)
    isOpen <- newIORef True
    let handleGoAway rsgaf = do
            writeIORef isOpen False
            return ()
    client <- newHttp2Client httpFrameConnection 4096 4096 conf handleGoAway ignoreFallbackHandler
    linkAsyncs client
    flowWorker <- forkIO $ forever $ do
        updated <- _updateWindow $ _incomingFlowControl client
        threadDelay 1000000

    workersem <- newQSem maxConcurrentStreams
    currtime <- round <$> getPOSIXTime :: IO Int64
    return $ ApnConnection client aci workersem currtime flowWorker isOpen


closeApnConnection :: ApnConnection -> IO ()
closeApnConnection connection = do
    writeIORef (apnConnectionOpen connection) False
    let flowWorker = apnConnectionFlowControlWorker connection
    killThread flowWorker
    _gtfo (apnConnectionConnection connection) HTTP2.NoError ""
    _close (apnConnectionConnection connection)


-- | Send a raw payload as a push notification message (advanced)
sendRawMessage
    :: ApnSession
    -- ^ Session to use
    -> ApnToken
    -- ^ Device to send the message to
    -> ByteString
    -- ^ The message to send
    -> IO ApnMessageResult
    -- ^ The response from the APN server
sendRawMessage s token payload = catchIOErrors $
    withConnection s $ \c ->
        sendApnRaw c token payload

-- | Send a push notification message.
sendMessage
    :: ApnSession
    -- ^ Session to use
    -> ApnToken
    -- ^ Device to send the message to
    -> JsonAps
    -- ^ The message to send
    -> IO ApnMessageResult
    -- ^ The response from the APN server
sendMessage s token payload = catchIOErrors $
    withConnection s $ \c ->
        sendApnRaw c token message
  where message = L.toStrict $ encode payload

-- | Send a silent push notification
sendSilentMessage
    :: ApnSession
    -- ^ Session to use
    -> ApnToken
    -- ^ Device to send the message to
    -> IO ApnMessageResult
    -- ^ The response from the APN server
sendSilentMessage s token = catchIOErrors $
    withConnection s $ \c ->
        sendApnRaw c token message
  where message = "{\"aps\":{\"content-available\":1}}"

ensureOpen :: ApnSession -> IO ()
ensureOpen s = do
    open <- isOpen s
    unless open $ error "Session is closed"

-- | Send a push notification message.
sendApnRaw
    :: ApnConnection
    -- ^ Connection to use
    -> ApnToken
    -- ^ Device to send the message to
    -> ByteString
    -- ^ The message to send
    -> IO ApnMessageResult
sendApnRaw connection token message = bracket_
  (waitQSem (apnConnectionWorkerPool connection))
  (signalQSem (apnConnectionWorkerPool connection)) $ do
    let requestHeaders = [ ( ":method", "POST" )
                  , ( ":scheme", "https" )
                  , ( ":authority", TE.encodeUtf8 hostname )
                  , ( ":path", "/3/device/" `S.append` token1 )
                  , ( "apns-topic", topic ) ]
        aci = apnConnectionInfo connection
        hostname = aciHostname aci
        topic = aciTopic aci
        client = apnConnectionConnection connection
        token1 = unApnToken token

    res <- _startStream client $ \stream ->
        let init = headers stream requestHeaders id
            handler isfc osfc = do
                -- sendData client stream (HTTP2.setEndStream) message
                upload message (HTTP2.setEndHeader . HTTP2.setEndStream) client (_outgoingFlowControl client) stream osfc
                let pph hStreamId hStream hHeaders hIfc hOfc =
                        print hHeaders
                response <- waitStream stream isfc pph
                let (errOrHeaders, frameResponses, _) = response
                case errOrHeaders of
                    Left err -> throwIO (ApnExceptionHTTP $ toErrorCodeId err)
                    Right hdrs1 -> do
                        let status = getHeaderEx ":status" hdrs1
                            reason = getHeaderEx ":reason" hdrs1

                        traceShowM errOrHeaders

                        return $ case status of
                            "200" -> ApnMessageResultOk
                            "400" -> decodeReason ApnMessageResultFatalError reason
                            "403" -> decodeReason ApnMessageResultFatalError reason
                            "405" -> decodeReason ApnMessageResultFatalError reason
                            "410" -> decodeReason ApnMessageResultFatalError reason
                            "413" -> decodeReason ApnMessageResultFatalError reason
                            "429" -> decodeReason ApnMessageResultTemporaryError reason
                            "500" -> decodeReason ApnMessageResultTemporaryError reason
                            "503" -> decodeReason ApnMessageResultTemporaryError reason
        in StreamDefinition init handler
    case res of
        Left _     -> return ApnMessageResultBackoff -- Too much concurrency
        Right res1 -> return res1

    where
        decodeReason :: FromJSON response => (response -> ApnMessageResult) -> ByteString -> ApnMessageResult
        decodeReason ctor = either (throw . ApnExceptionJSON) ctor . eitherDecode . L.fromStrict

        getHeaderEx :: HTTP2.HeaderName -> [HTTP2.Header] -> HTTP2.HeaderValue
        getHeaderEx name headers = fromMaybe (throw $ ApnExceptionMissingHeader name) (DL.lookup name headers)

catchIOErrors :: SpecifyError a => IO a -> IO a
catchIOErrors = flip catchIOError (return . isAnError)

-- The type of permanent error indicated by APNS
-- See https://apple.co/2RDCdWC table 8-6 for the meaning of each value.
data ApnFatalError = ApnFatalErrorBadCollapseId
                   | ApnFatalErrorBadDeviceToken
                   | ApnFatalErrorBadExpirationDate
                   | ApnFatalErrorBadMessageId
                   | ApnFatalErrorBadPriority
                   | ApnFatalErrorBadTopic
                   | ApnFatalErrorDevicetokenNotForTopic
                   | ApnFatalErrorDuplicateHeaders
                   | ApnFatalErrorIdleTimeout
                   | ApnFatalErrorMissingDeviceToken
                   | ApnFatalErrorMissingTopic
                   | ApnFatalErrorPayloadEmpty
                   | ApnFatalErrorTopicDisallowed
                   | ApnFatalErrorBadCertificate
                   | ApnFatalErrorBadCertificateEnvironment
                   | ApnFatalErrorExpiredProviderToken
                   | ApnFatalErrorForbidden
                   | ApnFatalErrorInvalidProviderToken
                   | ApnFatalErrorMissingProviderToken
                   | ApnFatalErrorBadPath
                   | ApnFatalErrorMethodNotAllowed
                   | ApnFatalErrorUnregistered
                   | ApnFatalErrorPayloadTooLarge
    deriving (Enum, Eq, Show, Generic)

instance FromJSON ApnFatalError where
    parseJSON = genericParseJSON defaultOptions { constructorTagModifier = drop 13 }

-- The type of transient error indicated by APNS
-- See https://apple.co/2RDCdWC table 8-6 for the meaning of each value.
data ApnTemporaryError = ApnTemporaryErrorTooManyProviderTokenUpdates
                       | ApnTemporaryErrorTooManyRequests
                       | ApnTemporaryErrorInternalServerError
                       | ApnTemporaryErrorServiceUnavailable
                       | ApnTemporaryErrorShutdown
    deriving (Enum, Eq, Show, Generic)

instance FromJSON ApnTemporaryError where
    parseJSON = genericParseJSON defaultOptions { constructorTagModifier = drop 17 }
