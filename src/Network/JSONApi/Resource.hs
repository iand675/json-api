{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving #-}
{- |
Module representing a JSON-API resource object.

Specification: <http://jsonapi.org/format/#document-resource-objects>
-}
module Network.JSONApi.Resource
( Resource(..)
, resIdentifier
, resValue
, resLinks
, resRelationships
, Relationships(..)
, ToResourcefulEntity (..)
, FromResourcefulEntity(..)
, fromResource
, Relationship
, relData
, relLinks
, RelationshipType(..)
, mkRelationship
, mkRelationships
) where

import Control.Applicative
import Control.Lens.TH
import Data.Aeson (ToJSON, FromJSON, (.=), (.:), (.:?))
import qualified Data.Aeson as AE
import qualified Data.Aeson.Types as AE
import Data.Functor.Classes
import Data.Hashable
import Data.Hashable.Lifted
import qualified Data.HashMap.Strict as HM
import Data.Maybe (catMaybes, fromMaybe)
import Data.Monoid
import Data.Semigroup
import Data.Text (Text)
import Data.These (These(..))
import GHC.Generics hiding (Meta)
import Network.JSONApi.Identifier (HasIdentifier (..), Identifier (..))
import Network.JSONApi.Link (Links(..))
import Network.JSONApi.Meta (Meta(..))
import Prelude hiding (id)

{- |
A type representing the Relationship between 2 entities

A Relationship provides basic information for fetching further information
about a related resource.

Specification: <http://jsonapi.org/format/#document-resource-object-relationships>
-}
data Relationship = Relationship
  { _data :: Maybe (RelationshipType Identifier)
  , _links :: Links
  } deriving (Show, Eq, Generic)

instance Hashable Relationship

relData :: Relationship -> Maybe (RelationshipType Identifier)
relData = _data

relLinks :: Relationship -> Links
relLinks = _links

instance AE.ToJSON Relationship where
  toJSON r = AE.object $ catMaybes
    [ maybe Nothing (Just . ("data" .=)) $ _data r
    , if HM.null (fromLinks $ _links r) then Nothing else Just ("links" .= _links r)
    ]

instance AE.FromJSON Relationship where
  parseJSON = AE.withObject "relationship" $ \r -> do
    d <- r .:? "data"
    l <- r .:? "links"
    return $ Relationship d (fromMaybe mempty l)

newtype Relationships = Relationships { fromRelationships :: HM.HashMap Text Relationship }
  deriving (Show, Eq, Generic, Semigroup, Monoid, ToJSON, FromJSON)

deriving instance Hashable Relationships

data RelationshipType a
  = ToOne (Maybe a)
  | ToMany [a]
  deriving (Show, Eq, Functor, Generic, Generic1)

instance Hashable1 RelationshipType
instance Hashable a => Hashable (RelationshipType a)

instance (ToJSON a) => ToJSON (RelationshipType a) where
  toJSON rel = case rel of
    ToOne mval -> case mval of
      Nothing -> AE.Null
      Just a -> AE.toJSON a
    ToMany vals -> AE.toJSON vals

instance (FromJSON a) => FromJSON (RelationshipType a) where
  parseJSON AE.Null = pure $ ToOne Nothing
  parseJSON o@(AE.Object _) = (ToOne . Just) <$> AE.parseJSON o
  parseJSON a@(AE.Array _) = ToMany <$> AE.parseJSON a
  parseJSON wat = AE.typeMismatch "RelationshipType" wat

{- |
Type representing a JSON-API resource object.

A Resource supplies standardized data and metadata about a resource.

Specification: <http://jsonapi.org/format/#document-resource-objects>
-}
data Resource a = Resource
  { _resIdentifier :: Identifier
  , _resValue :: a
  , _resLinks :: Links
  , _resRelationships :: Relationships
  } deriving (Show, Eq, Generic, Generic1, Functor)

makeFields ''Resource

instance Hashable a => Hashable (Resource a)
instance Hashable1 Resource

instance Eq1 Resource where
  liftEq eq_ r1 r2 =
    _resIdentifier r1 == _resIdentifier r2 &&
    eq_ (_resValue r1) (_resValue r2) &&
    _resLinks r1 == _resLinks r2 &&
    _resRelationships r1 == _resRelationships r2

instance Show1 Resource where
  liftShowsPrec sp _ p f =
    showString "Resource { identifier =" .
    showsPrec p (_resIdentifier f) .
    showString ", value = " .
    (sp p $ _resValue f) .
    showString ", links = " .
    showsPrec p (_resLinks f) .
    showString ", relationships = " .
    showsPrec p (_resRelationships f) .
    showString "}"

instance AE.ToJSON1 Resource where
  liftToJSON f1 _ (Resource (Identifier resId resType metaObj) resObj linksObj rels) =
    AE.object (["type" .= resType, "attributes" .= f1 resObj] ++ optionals)
    where
      optionals = catMaybes
        [ ("id" .=) <$> resId
        , ("attributes" .=) <$> case f1 resObj of
            AE.Null -> Nothing
            AE.Object o -> if HM.null o then Nothing else Just $ AE.Object o
            validish -> Just validish
        , if (HM.null $ fromLinks linksObj) then Nothing else Just ("links" .= linksObj)
        , if (HM.null $ fromMeta metaObj) then Nothing else Just ("meta" .= metaObj)
        , if (HM.null $ fromRelationships rels) then Nothing else Just ("relationships" .= rels)
        ]

instance AE.FromJSON1 Resource where
  liftParseJSON p1 _ = AE.withObject "resourceObject" $ \v -> do
    id    <- v .:? "id"
    typ   <- v .: "type"
    attrs <- v .:? "attributes"
    attrs' <- case attrs of
      Nothing -> p1 AE.Null <|> p1 (AE.Object HM.empty)
      Just as -> p1 as
    links <- v .:? "links"
    meta  <- v .:? "meta"
    rels  <- v .:? "relationships"
    return $ Resource
      (Identifier id typ $ fromMaybe mempty meta)
      attrs'
      (fromMaybe mempty links)
      (fromMaybe mempty rels)

instance (ToJSON a) => ToJSON (Resource a) where
  toJSON = AE.toJSON1

instance (FromJSON a) => FromJSON (Resource a) where
  parseJSON = AE.parseJSON1

instance HasIdentifier (Resource a) where
  resourceType = _datatype . _resIdentifier
  identifier = _resIdentifier

{- |
A typeclass for decorating an entity with JSON API properties
-}
class (Applicative m, HasIdentifier a) => ToResourcefulEntity m a where
  type ResourceValue a :: *
  type ResourceValue a = a

  resourceIdentifier :: a -> m (Maybe Text)
  resourceIdentifier = pure . const Nothing

  resourceLinks :: a -> m Links
  resourceLinks = pure . const mempty

  resourceMetaData :: a -> m Meta
  resourceMetaData = pure . const mempty

  resourceRelationships :: a -> m Relationships
  resourceRelationships = pure . const mempty

  toResource :: a -> m (Resource (ResourceValue a))
  default toResource :: (ResourceValue a ~ a) => a -> m (Resource (ResourceValue a))
  toResource a = Resource
    <$> (Identifier <$> resourceIdentifier a <*> pure (resourceType a) <*> resourceMetaData a)
    <*> pure a
    <*> resourceLinks a
    <*> resourceRelationships a

class FromResourcefulEntity a where
  fromResource' :: Resource (ResourceValue a) -> AE.Parser a
  default fromResource' :: (ResourceValue a ~ a) => Resource (ResourceValue a) -> AE.Parser a
  fromResource' = return . _resValue

instance Applicative m => ToResourcefulEntity m (Resource a) where
  type ResourceValue (Resource a) = a
  resourceIdentifier = pure . _ident . _resIdentifier
  resourceLinks = pure . _resLinks
  resourceRelationships = pure . _resRelationships
  toResource = pure

instance FromResourcefulEntity (Resource a) where
  fromResource' = return

fromResource :: FromResourcefulEntity a => Resource (ResourceValue a) -> Either String a
fromResource = AE.parseEither fromResource'

mkRelationships :: [(Text, Relationship)] -> Relationships
mkRelationships = Relationships . HM.fromList


{- |
Constructor function for creating a Relationship record

A relationship must contain either an Identifier or a Links record
-}
mkRelationship :: These (RelationshipType Identifier) Links -> Relationship
mkRelationship (This resId) = Relationship (Just resId) mempty
mkRelationship (That links) = Relationship Nothing links
mkRelationship (These resId links) = Relationship (Just resId) links

makeLenses ''Resource
