{-# OPTIONS_GHC -fno-warn-orphans #-}

{-# LANGUAGE QuantifiedConstraints #-}

module Radicle.Daemon.HttpApi
    ( QueryRequestF(..)
    , QueryRequest
    , QueryResponseF(..)
    , QueryResponse
    , machineQueryEndpoint

    , SendRequestF(..)
    , SendRequest
    , SendResponseF(..)
    , SendResponse
    , machineSendEndpoint

    , NewResponse(..)
    , newMachineEndpoint

    , DaemonApi
    , daemonApi

    , swagger

    , MachineId(..)
    ) where

import           Protolude

import qualified Data.Aeson as A
import qualified Data.Aeson.Types as A
import           Data.Swagger
import           Data.Version (showVersion)
import qualified Network.HTTP.Media as HttpMedia
import           Radicle.Daemon.Ipfs
import           Servant.API
import           Servant.Swagger

import qualified Paths_radicle as Radicle
import qualified Radicle.Internal.Annotation as Ann
import           Radicle.Internal.Core
import           Radicle.Internal.Json
import           Radicle.Internal.Parse
import           Radicle.Internal.Pretty

-- | Content type for values encoded as Radicle expression.
data RadicleData

instance Accept RadicleData where
  contentType _ = "application" HttpMedia.// "radicle"

instance ToRad Ann.WithPos a => MimeRender RadicleData a where
  mimeRender _ = toS . renderCompactPretty . (toRad :: a -> Value)

instance FromRad Ann.WithPos a => MimeUnrender RadicleData a where
  mimeUnrender _ = first toS . (fromRad <=< parse "[daemon]") . toS

-- | Content type for values encoded *loosely* as JSON. This encoding is meant
-- to be convenient (for consuming in the browser) but lossy (since JSON has
-- less value types and JSON objects can only have strings as keys). In
-- particular, when dict keys are keywords, booleans or numbers, they are
-- converted to strings.
data RadicleJSON

instance Accept RadicleJSON where
  contentType _ = "application" HttpMedia.// "radicle-json"

instance (Traversable t, A.ToJSON (t A.Value)) => MimeRender RadicleJSON (t Value) where
  mimeRender _ x = case traverse maybeJson x of
    Right y -> A.encode y
    Left e -> A.encode $ A.object [("error", A.String ("Radicle value did not have a JSON representation: " <> e))]

instance (Functor t, A.FromJSON (t A.Value)) => MimeUnrender RadicleJSON (t Value) where
  mimeUnrender _ = fmap (fmap fromJson) . A.eitherDecode . toS

instance (Traversable t, A.ToJSON (t A.Value)) => MimeRender JSON (t Value) where
  mimeRender _ = A.encode . fmap valueToJson

instance {-# OVERLAPPING #-} (Traversable t, A.FromJSON (t A.Value)) => MimeUnrender JSON (t Value) where
  mimeUnrender _ = A.parseEither (traverse jsonToValue) <=< A.eitherDecode . toS

instance FromHttpApiData MachineId where
    parseUrlPiece = Right . MachineId . toS
    parseQueryParam = parseUrlPiece

instance ToHttpApiData MachineId where
    toUrlPiece (MachineId id) = id

newtype QueryRequestF a = QueryRequest { expression :: a }
  deriving (Functor, Foldable, Traversable, Generic)

instance A.ToJSON a => A.ToJSON (QueryRequestF a)
instance A.FromJSON a => A.FromJSON (QueryRequestF a)

type QueryRequest = QueryRequestF Value

instance FromRad Ann.WithPos QueryRequest
instance ToRad Ann.WithPos QueryRequest

newtype QueryResponseF v = QueryResponse { result :: v }
  deriving (Functor, Foldable, Traversable, Generic)

instance A.ToJSON a => A.ToJSON (QueryResponseF a)
instance A.FromJSON a => A.FromJSON (QueryResponseF a)

type QueryResponse = QueryResponseF Value

instance FromRad Ann.WithPos QueryResponse
instance ToRad Ann.WithPos QueryResponse

newtype SendRequestF v = SendRequest { expressions :: [v] }
  deriving (Functor, Foldable, Traversable, Generic)

instance A.ToJSON a => A.ToJSON (SendRequestF a)
instance A.FromJSON a => A.FromJSON (SendRequestF a)

type SendRequest = SendRequestF Value

instance FromRad Ann.WithPos SendRequest
instance ToRad Ann.WithPos SendRequest

newtype SendResponseF v = SendResponse
  { results :: [v]
  } deriving (Functor, Foldable, Traversable, Generic)

instance A.ToJSON a => A.ToJSON (SendResponseF a)
instance A.FromJSON a => A.FromJSON (SendResponseF a)

type SendResponse = SendResponseF Value

instance FromRad Ann.WithPos SendResponse
instance ToRad Ann.WithPos SendResponse

newtype NewResponse = NewResponse
  { machineId :: MachineId
  } deriving (Generic)

instance ToRad Ann.WithPos MachineId
instance FromRad Ann.WithPos MachineId

instance ToRad Ann.WithPos NewResponse
instance FromRad Ann.WithPos NewResponse

instance A.ToJSON NewResponse
instance A.FromJSON NewResponse

-- * APIs

type Formats = '[RadicleData, JSON, RadicleJSON]

type MachinesEndpoint t = "v0" :> "machines" :> t
type MachineEndpoint t = MachinesEndpoint (Capture "machineId" MachineId :> t)

type MachineQueryEndpoint = MachineEndpoint ("query" :> ReqBody Formats QueryRequest :> Post Formats QueryResponse)
machineQueryEndpoint :: Proxy MachineQueryEndpoint
machineQueryEndpoint = Proxy

type MachineSendEndpoint = MachineEndpoint ("send" :> ReqBody Formats SendRequest :> Post Formats SendResponse)
machineSendEndpoint :: Proxy MachineSendEndpoint
machineSendEndpoint = Proxy

type NewMachineEndpoint = MachinesEndpoint ("new" :> Post '[JSON, RadicleData] NewResponse)
newMachineEndpoint :: Proxy NewMachineEndpoint
newMachineEndpoint = Proxy

type DaemonApi =
         NewMachineEndpoint
    :<|> MachineQueryEndpoint
    :<|> MachineSendEndpoint
    :<|> "v0" :> "docs" :> Get '[JSON] Swagger

daemonApi :: Proxy DaemonApi
daemonApi = Proxy

-- * Docs

instance ToParamSchema MachineId where
  toParamSchema _ = mempty { _paramSchemaType = SwaggerString }
instance ToSchema MachineId where
  declareNamedSchema pxy = pure $
    NamedSchema (Just "MachineId") $
      mempty { _schemaDescription = Just "The ID (i.e. IPNS name) of an IPFS machine."
             , _schemaParamSchema = toParamSchema pxy }

instance ToSchema Value where
  declareNamedSchema _ = pure $
    NamedSchema (Just "RadicleValue") $
      mempty { _schemaDescription = Just "A radicle value formatted according to radicle's S-expression syntax."
             , _schemaParamSchema = mempty {_paramSchemaType = SwaggerString } }

instance ToSchema QueryRequest
instance ToSchema QueryResponse
instance ToSchema SendRequest
instance ToSchema SendResponse
instance ToSchema NewResponse

instance ToSchema Swagger where
  declareNamedSchema _ = pure $
    NamedSchema (Just "Swagger") $
      mempty { _schemaDescription = Just "This swagger spec."
             , _schemaParamSchema = mempty { _paramSchemaType = SwaggerObject }}

swagger :: Swagger
swagger = swag { _swaggerInfo = inf }
  where
    inf = mempty { _infoTitle = "Radicle daemon"
                 , _infoDescription = Just desc
                 , _infoVersion = toS $ showVersion Radicle.version
                 }
    swag = toSwagger daemonApi
    desc =
      "The radicle-daemon; a long-running background process which\
      \ materialises the state of remote IPFS machines on the users\
      \ PC, and writes to those IPFS machines the user is an owner of."
