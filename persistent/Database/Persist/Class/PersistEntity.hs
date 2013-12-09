{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleInstances, FlexibleContexts #-}
{-# LANGUAGE EmptyDataDecls, TypeSynonymInstances #-}
module Database.Persist.Class.PersistEntity
    ( PersistEntity (..)
    , Key
    , IKey
    , DbSpecific
    , Backend (..)
    , Update (..)
    , SelectOpt (..)
    , BackendSpecificFilter
    , Filter (..)
    , Entity (..)

    , keyValueEntityToJSON, keyValueEntityFromJSON
    , entityIdToJSON, entityIdFromJSON
    ) where

import Database.Persist.Types.Base
import Database.Persist.Class.PersistField
import Data.Text (Text)
import Data.Aeson (ToJSON (..), FromJSON (..), object, (.:), (.=), Value (Object))
import Data.Aeson.Types (Parser)
import Control.Applicative ((<$>), (<*>))
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import Data.Monoid (mappend)

-- | Persistent serializes Haskell records to the database.
-- A Database 'Entity' (A row in SQL, a document in MongoDB, etc)
-- corresponds to a 'Key' plus a Haskell record.
--
-- For every Haskell record type stored in the database there is a corresponding 'PersistEntity' instance.
-- An instance of PersistEntity contains meta-data for the record.
-- PersistEntity also helps abstract over different record types.
-- That means the same query interface can return a 'PersistEntity', with each query returning different types of Haskell records.
--
-- Some advanced type system capabilities are used to make this process type-safe.
-- Normal usage of the persistent API does not require understanding the class associated data and functions.
class (PersistField record) => PersistEntity record where
    -- | An 'EntityField' is parameterised by the Haskell record it belongs to
    -- and the additional type of that field
    data EntityField record fieldType

    -- | return meta-data for a given 'EntityField'
    persistFieldDef :: EntityField record fieldType -> FieldDef

    -- | all of the keys
    -- possibly an auto-generated key
    -- and all the uniques
    data Keys record keytype
    fromKey :: PersistField a => Keys record typ -> a

    -- | The type of the primary key (Key)
    -- Could be a key generated on insert (IKey) or a unique key (Unique).
    type KeyType record

    persistValueToPersistKey :: PersistValue -> Key record
    persistKeyToPersistValue :: Key record -> PersistValue

    persistIdField :: EntityField record (Key record)

    -- | Unique keys besides the Key generated on insertion
    data Unique record

    persistUniqueToFieldNames :: Unique record -> [(HaskellName, DBName)]
    persistUniqueToValues :: Unique record -> [PersistValue]
    persistUniqueKeys :: record -> [Unique record]
    -- fromUnique :: Unique record -> a

    -- | retrieve the EntityDef meta-data for the record
    entityDef :: record -> EntityDef

    -- | Get the database fields of a record
    toPersistFields :: record -> [SomePersistField]

    -- | Convert from database values to a Haskell record
    fromPersistValues :: [PersistValue] -> Either Text record

    fieldLens :: EntityField record field
              -> (forall f. Functor f => (field -> f field) -> Entity record -> f (Entity record))

-- | A simpler way to refer to the primary key
type Key record = Keys record (KeyType record)
-- | The Key generated on insertion, could be ()
type IKey record = Keys record DbSpecific
type UKey record field = Keys record (Uniq field)

data Uniq (u :: (* -> *) -> *)

class (PersistField (BackendKey db)) => Backend db where
  type BackendKey db
  -- fromIKey :: IKey record -> BackendKey db

instance (PersistEntity record, KeyType record ~ typ) =>
  PersistField (Keys record typ) where
    toPersistValue = persistKeyToPersistValue
    fromPersistValue = Right . persistValueToPersistKey

instance KeyType record ~ typ => Eq   (Keys record typ)
instance KeyType record ~ typ => Ord  (Keys record typ)
instance KeyType record ~ typ => Read (Keys record typ)
instance KeyType record ~ typ => Show (Keys record typ)

instance (KeyType record ~ typ, PersistEntity record) => ToJSON (Keys record typ) where
    toJSON = toJSON . persistKeyToPersistValue
instance (KeyType record ~ typ, PersistEntity record) => FromJSON (Keys record typ) where
    parseJSON = fmap persistValueToPersistKey . parseJSON

-- | Used for marking the primary key
data DbSpecific

-- | updataing a database entity
--
-- Persistent users use combinators to create these
data Update record = forall typ. PersistField typ => Update
    { updateField :: EntityField record typ
    , updateValue :: typ
    -- FIXME Replace with expr down the road
    , updateUpdate :: PersistUpdate
    }

-- | query options
--
-- Persistent users use these directly
data SelectOpt record = forall typ. Asc  (EntityField record typ)
                      | forall typ. Desc (EntityField record typ)
                      | OffsetBy Int
                      | LimitTo Int

type family BackendSpecificFilter backend record

-- | Filters which are available for 'select', 'updateWhere' and
-- 'deleteWhere'. Each filter constructor specifies the field being
-- filtered on, the type of comparison applied (equals, not equals, etc)
-- and the argument for the comparison.
--
-- Persistent users use combinators to create these
data Filter backend record = forall typ. PersistField typ => Filter
    { filterField  :: EntityField record typ
    , filterValue  :: Either typ [typ] -- FIXME
    , filterFilter :: PersistFilter -- FIXME
    }
    | FilterAnd [Filter backend record] -- ^ convenient for internal use, not needed for the API
    | FilterOr  [Filter backend record]
    | BackendFilter
          (BackendSpecificFilter backend record)

-- | Datatype that represents an entity, with both its 'Key' and
-- its Haskell record representation.
--
-- When using a SQL-based backend (such as SQLite or
-- PostgreSQL), an 'Entity' may take any number of columns
-- depending on how many fields it has. In order to reconstruct
-- your entity on the Haskell side, @persistent@ needs all of
-- your entity columns and in the right order.  Note that you
-- don't need to worry about this when using @persistent@\'s API
-- since everything is handled correctly behind the scenes.
--
-- However, if you want to issue a raw SQL command that returns
-- an 'Entity', then you have to be careful with the column
-- order.  While you could use @SELECT Entity.* WHERE ...@ and
-- that would work most of the time, there are times when the
-- order of the columns on your database is different from the
-- order that @persistent@ expects (for example, if you add a new
-- field in the middle of you entity definition and then use the
-- migration code -- @persistent@ will expect the column to be in
-- the middle, but your DBMS will put it as the last column).
-- So, instead of using a query like the one above, you may use
-- 'Database.Persist.GenericSql.rawSql' (from the
-- "Database.Persist.GenericSql" module) with its /entity
-- selection placeholder/ (a double question mark @??@).  Using
-- @rawSql@ the query above must be written as @SELECT ??  WHERE
-- ..@.  Then @rawSql@ will replace @??@ with the list of all
-- columns that we need from your entity in the right order.  If
-- your query returns two entities (i.e. @(Entity backend a,
-- Entity backend b)@), then you must you use @SELECT ??, ??
-- WHERE ...@, and so on.
data Entity record =
    Entity { entityKey :: Key record
           , entityVal :: record }
    deriving (Eq, Ord, Read, Show)

-- | Predefined @toJSON@. The resulting JSON looks like
-- @{\"key\": 1, \"value\": {\"name\": ...}}@.
--
-- The typical usage is:
--
-- @
--   instance ToJSON User where
--       toJSON = keyValueEntityToJSON
-- @
keyValueEntityToJSON :: (ToJSON record, ToJSON (Key record)) => Entity record -> Value
keyValueEntityToJSON (Entity key value) = object
    [ "key" .= key
    , "value" .= value
    ]

-- | Predefined @parseJSON@. The input JSON looks like
-- @{\"key\": 1, \"value\": {\"name\": ...}}@.
--
-- The typical usage is:
--
-- @
--   instance FromJSON User where
--       parseJSON = keyValueEntityFromJSON
-- @
keyValueEntityFromJSON :: (FromJSON e, FromJSON (Key e)) => Value -> Parser (Entity e)
keyValueEntityFromJSON (Object o) = Entity
    <$> o .: "key"
    <*> o .: "value"
keyValueEntityFromJSON _ = fail "keyValueEntityFromJSON: not an object"

-- | Predefined @toJSON@. The resulting JSON looks like
-- @{\"id\": 1, \"name\": ...}@.
--
-- The typical usage is:
--
-- @
--   instance ToJSON User where
--       toJSON = entityIdToJSON
-- @
entityIdToJSON :: (ToJSON e, ToJSON (Key e)) => Entity e -> Value
entityIdToJSON (Entity key value) = case toJSON value of
    Object o -> Object $ HM.insert "id" (toJSON key) o
    x -> x

-- | Predefined @parseJSON@. The input JSON looks like
-- @{\"id\": 1, \"name\": ...}@.
--
-- The typical usage is:
--
-- @
--   instance FromJSON User where
--       parseJSON = entityIdFromJSON
-- @
entityIdFromJSON :: (FromJSON e, FromJSON (Key e)) => Value -> Parser (Entity e)
entityIdFromJSON value@(Object o) = Entity <$> o .: "id" <*> parseJSON value
entityIdFromJSON _ = fail "entityIdFromJSON: not an object"

instance (PersistEntity record, PersistField record) => PersistField (Entity record) where
    toPersistValue (Entity key value) = case toPersistValue value of
        (PersistMap alist) -> PersistMap ((idField, toPersistValue key) : alist)
        _ -> error $ T.unpack $ errMsg "expected PersistMap"

    fromPersistValue (PersistMap alist) = case after of
        [] -> Left $ errMsg $ "did not find " `mappend` idField `mappend` " field"
        ("_id", k):afterRest ->
            case fromPersistValue (PersistMap (before ++ afterRest)) of
                Right record -> Right $ Entity (persistValueToPersistKey k) record
                Left err     -> Left err
        _ -> Left $ errMsg $ "impossible id field: " `mappend` T.pack (show alist)
      where
        (before, after) = break ((== idField) . fst) alist

    fromPersistValue x = Left $
          errMsg "Expected PersistMap, received: " `mappend` T.pack (show x)

errMsg :: Text -> Text
errMsg = mappend "PersistField entity fromPersistValue: "

-- | Realistically this is only going to be used for MongoDB,
-- so lets use MongoDB conventions
idField :: Text
idField = "_id"
