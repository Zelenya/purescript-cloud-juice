module Nakadi.Client.Internal where

import Prelude

import Affjax (Request, Response, ResponseFormatError, printResponseFormatError)
import Affjax as AX
import Affjax.RequestBody as RequestBody
import Affjax.RequestHeader (RequestHeader(..))
import Affjax.ResponseFormat as ResponseFormat
import Affjax.StatusCode (StatusCode(..))
import Control.Alt ((<|>))
import Control.Monad.Error.Class (class MonadThrow, throwError)
import Control.Monad.Reader (class MonadAsk, ask, runReaderT)
import Data.Array as Array
import Data.Bifunctor (lmap)
import Data.Either (Either(..), either)
import Data.Foldable (class Foldable, foldMap)
import Data.HTTP.Method (Method(..))
import Data.Maybe (Maybe(..), fromMaybe, isJust, maybe)
import Data.Newtype (unwrap)
import Data.Options ((:=))
import Data.String as String
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Data.Variant (Variant)
import Debug.Trace (spy)
import Effect (Effect)
import Effect.Aff (Aff, effectCanceler, forkAff, makeAff, runAff_)
import Effect.Aff.AVar (AVar)
import Effect.Aff.AVar as AVar
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (liftEffect)
import Effect.Console as Console
import Effect.Exception (Error, error, throwException)
import Effect.Ref as Ref
import FlowId.Types (FlowId)
import Foreign (ForeignError, renderForeignError)
import Foreign.Object as Object
import Gzip.Gzip as Gzip
import Nakadi.Client.Types (Env)
import Nakadi.Errors (E207, E400, E401, E403, E404, E409, E422, e207, e400, e401, e403, e404, e409, e422)
import Nakadi.Types (Cursor, CursorDistanceQuery, CursorDistanceResult, Event, EventType, EventTypeName(..), Partition, Problem, StreamParameters, Subscription, SubscriptionCursor, SubscriptionEventStreamBatch, SubscriptionId(..), XNakadiStreamId(..))
import Node.Encoding (Encoding(..))
import Node.HTTP.Client as HTTP
import Node.Stream (onDataString, onEnd, pipe)
import Node.Stream as Stream
import Simple.JSON (class ReadForeign, class WriteForeign, readJSON, writeJSON)

request :: ∀ a m. MonadAff m => Request a -> m (Response (Either ResponseFormatError a))
request = liftAff <<< AX.request

baseHeaders :: ∀ r m . MonadAsk (Env r) m => MonadAff m => m (Array (Tuple String String))
baseHeaders = do
  env <- ask
  token <- liftEffect $ env.token
  pure [ Tuple "X-Flow-ID" (unwrap env.flowId)
       , Tuple "Authorization" ("Bearer " <> token)
       ]

baseRequest :: ∀ r m . MonadAsk (Env r) m => MonadAff m => Method -> String -> m (Request String)
baseRequest method path = do
  env <- ask
  headers <- baseHeaders <#> (map \(Tuple k v) -> RequestHeader k v)
  let port = show env.port
  pure $
    AX.defaultRequest
    { method = Left method
    , responseFormat = ResponseFormat.string
    , headers = headers
    , url = env.baseUrl <> ":" <> port <> path
    }

getRequest :: ∀ r m. MonadAsk (Env r) m => MonadAff m => String -> m (Request String)
getRequest = baseRequest GET

deleteRequest :: ∀ r m. MonadAsk (Env r) m => MonadAff m => String -> m (Request String)
deleteRequest = baseRequest DELETE

writeRequest :: ∀ a m r. WriteForeign a => MonadAsk (Env r) m => MonadAff m => Method -> String -> a -> m (Request String)
writeRequest method path content = do
  req <- baseRequest method path
  let contentString = writeJSON content -- # spy "Body to send"
  let body = Just (RequestBody.string contentString)
  let headers = req.headers <> [RequestHeader "Content-Type" "application/json"]
  pure $ req
    { content = body
    , headers = headers
    }

postRequest :: ∀ a m r . WriteForeign a => MonadAsk (Env r) m => MonadAff m => String -> a -> m (Request String)
postRequest = writeRequest POST

putRequest :: ∀ a m r . WriteForeign a => MonadAsk (Env r) m => MonadAff m => String -> a -> m (Request String)
putRequest = writeRequest PUT

formatErr :: ∀ m a. MonadThrow Error m => ResponseFormatError -> m a
formatErr = throwError <<< error <<< printResponseFormatError -- >>> spy "Response Format Error"

jsonErr :: ∀ m f a.  MonadThrow Error m => Foldable f => f ForeignError -> m a
jsonErr = throwError <<< error <<< foldMap renderForeignError -- >>> spy "Foreign error"

deserialiseProblem :: ∀ m a b. MonadThrow Error m => ReadForeign a => Either ResponseFormatError String -> m (Either a b)
deserialiseProblem = either formatErr (readJSON >>> either jsonErr (pure <<< Left))

readJson :: ∀ m f a. MonadThrow Error m => ReadForeign a => Applicative f => Either ResponseFormatError String -> m (f a)
readJson = either formatErr (readJSON >>> either jsonErr (pure <<< pure))

deserialise_ :: ∀ m . MonadThrow Error m => Response (Either ResponseFormatError String) -> m (Either Problem Unit)
deserialise_ { body, status: StatusCode code} =
    if code # between 200 299
      then pure <<< pure $ unit
      else deserialiseProblem body -- # spy "Broken Response"

deserialise :: ∀ m a . MonadThrow Error m => ReadForeign a => Response (Either ResponseFormatError String) -> m (Either Problem a)
deserialise { body, status: StatusCode code} =
    if code # between 200 299
      then readJson body -- # spy "Happy Response" body
      else deserialiseProblem body # spy "Broken Response"

unhandled :: ∀ a m. MonadThrow Error m => Problem -> m a
unhandled p = throwError <<< error $ "Unhandled response code " <> writeJSON p

catchErrors
  :: ∀ a b m m'
   . Applicative m
  => Applicative m'
  => (a -> m (m' b))
  -> Either a b
  -> m (m' b)
catchErrors f = case _ of
  Left p -> f p
  Right r -> pure <<< pure $ r