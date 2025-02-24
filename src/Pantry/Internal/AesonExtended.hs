{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- | Extensions to Aeson parsing of objects. This module is intended
-- for internal use by Pantry and Stack only. The intention is to
-- fully remove this module in the future. /DO NOT RELY ON IT/.
module Pantry.Internal.AesonExtended (
    module Export
  -- * Extended failure messages
  , (.:)
  , (.:?)
  -- * JSON Parser that emits warnings
  , JSONWarning (..)
  , WarningParser
  , WithJSONWarnings (..)
  , withObjectWarnings
  , jsonSubWarnings
  , jsonSubWarningsT
  , jsonSubWarningsTT
  , logJSONWarnings
  , noJSONWarnings
  , tellJSONField
  , unWarningParser
  , (..:)
  , (...:)
  , (..:?)
  , (...:?)
  , (..!=)
  ) where

import Control.Monad.Trans.Writer.Strict (WriterT, mapWriterT, runWriterT, tell)
import Data.Aeson as Export hiding ((.:), (.:?))
import qualified Data.Aeson as A
import Data.Aeson.Key (toString, toText)
import Data.Aeson.KeyMap (member, keys)
import Data.Aeson.Types hiding ((.:), (.:?))
import qualified Data.Set as Set
import qualified Data.Text as T
import Generics.Deriving.Monoid (mappenddefault, memptydefault)
import RIO
import RIO.PrettyPrint.StylesUpdate (StylesUpdate)

-- | Extends @.:@ warning to include field name.
(.:) :: FromJSON a => Object -> Key -> Parser a
(.:) o p = modifyFailure (("failed to parse field '" <> toString p <> "': ") <>) (o A..: p)
{-# INLINE (.:) #-}

-- | Extends @.:?@ warning to include field name.
(.:?) :: FromJSON a => Object -> Key -> Parser (Maybe a)
(.:?) o p = modifyFailure (("failed to parse field '" <> toString p <> "': ") <>) (o A..:? p)
{-# INLINE (.:?) #-}

-- | 'WarningParser' version of @.:@.
(..:)
    :: FromJSON a
    => Object -> Key -> WarningParser a
o ..: k = tellJSONField k >> lift (o .: k)

-- | 'WarningParser' version of @.:?@.
(..:?)
    :: FromJSON a
    => Object -> Key -> WarningParser (Maybe a)
o ..:? k = tellJSONField k >> lift (o .:? k)

-- | 'WarningParser' version of @.!=@.
(..!=) :: WarningParser (Maybe a) -> a -> WarningParser a
wp ..!= d =
    flip mapWriterT wp $
    \p ->
         do a <- fmap snd p
            fmap (, a) (fmap fst p .!= d)

presentCount :: Object -> [Key] -> Int
presentCount o ss = length . filter (\x -> member x o) $ ss

-- | Synonym version of @..:@.
(...:) :: FromJSON a => Object -> [Key] -> WarningParser a
_ ...: [] = fail "failed to find an empty key"
o ...: ss@(key:_) = apply
    where pc = presentCount o ss
          apply | pc == 0   = fail $
                                "failed to parse field " ++
                                show key ++ ": " ++
                                "keys " ++ show ss ++ " not present"
                | pc >  1   = fail $
                                "failed to parse field " ++
                                show key ++ ": " ++
                                "two or more synonym keys " ++
                                show ss ++ " present"
                | otherwise = asum $ map (o..:) ss

-- | Synonym version of @..:?@.
(...:?) :: FromJSON a => Object -> [Key] -> WarningParser (Maybe a)
_ ...:? [] = fail "failed to find an empty key"
o ...:? ss@(key:_) = apply
    where pc = presentCount o ss
          apply | pc == 0   = return Nothing
                | pc >  1   = fail $
                                "failed to parse field " ++
                                show key ++ ": " ++
                                "two or more synonym keys " ++
                                show ss ++ " present"
                | otherwise = asum $ map (o..:) ss

-- | Tell warning parser about an expected field, so it doesn't warn about it.
tellJSONField :: Key -> WarningParser ()
tellJSONField key = tell (mempty { wpmExpectedFields = Set.singleton key})

-- | 'WarningParser' version of 'withObject'.
withObjectWarnings :: String
                   -> (Object -> WarningParser a)
                   -> Value
                   -> Parser (WithJSONWarnings a)
withObjectWarnings expected f =
    withObject expected $
    \obj ->
         do (a,w) <- runWriterT (f obj)
            let unrecognizedFields =
                    Set.toList
                        (Set.difference
                             (Set.fromList (keys obj))
                             (wpmExpectedFields w))
            return
                (WithJSONWarnings a
                    (wpmWarnings w ++
                     case unrecognizedFields of
                         [] -> []
                         _ -> [JSONUnrecognizedFields expected unrecognizedFields]))

-- | Convert a 'WarningParser' to a 'Parser'.
unWarningParser :: WarningParser a -> Parser a
unWarningParser wp = do
    (a,_) <- runWriterT wp
    return a

-- | Log JSON warnings.
logJSONWarnings
    :: (MonadReader env m, HasLogFunc env, HasCallStack, MonadIO m)
    => FilePath -> [JSONWarning] -> m ()
logJSONWarnings fp =
    mapM_ (\w -> logWarn ("Warning: " <> fromString fp <> ": " <> displayShow w))

-- | Handle warnings in a sub-object.
jsonSubWarnings :: WarningParser (WithJSONWarnings a) -> WarningParser a
jsonSubWarnings f = do
    WithJSONWarnings result warnings <- f
    tell
        (mempty
         { wpmWarnings = warnings
         })
    return result

-- | Handle warnings in a @Traversable@ of sub-objects.
jsonSubWarningsT
    :: Traversable t
    => WarningParser (t (WithJSONWarnings a)) -> WarningParser (t a)
jsonSubWarningsT f =
    mapM (jsonSubWarnings . return) =<< f

-- | Handle warnings in a @Maybe Traversable@ of sub-objects.
jsonSubWarningsTT
    :: (Traversable t, Traversable u)
    => WarningParser (u (t (WithJSONWarnings a)))
    -> WarningParser (u (t a))
jsonSubWarningsTT f =
    mapM (jsonSubWarningsT . return) =<< f

-- Parsed JSON value without any warnings
noJSONWarnings :: a -> WithJSONWarnings a
noJSONWarnings v = WithJSONWarnings v []

-- | JSON parser that warns about unexpected fields in objects.
type WarningParser a = WriterT WarningParserMonoid Parser a

-- | Monoid used by 'WarningParser' to track expected fields and warnings.
data WarningParserMonoid = WarningParserMonoid
    { wpmExpectedFields :: !(Set Key)
    , wpmWarnings :: [JSONWarning]
    } deriving Generic
instance Semigroup WarningParserMonoid where
    (<>) = mappenddefault
instance Monoid WarningParserMonoid where
    mempty = memptydefault
    mappend = (<>)
instance IsString WarningParserMonoid where
    fromString s = mempty { wpmWarnings = [fromString s] }

-- Parsed JSON value with its warnings
data WithJSONWarnings a = WithJSONWarnings a [JSONWarning]
    deriving (Eq, Generic, Show)
instance Functor WithJSONWarnings where
    fmap f (WithJSONWarnings x w) = WithJSONWarnings (f x) w
instance Monoid a => Semigroup (WithJSONWarnings a) where
    (<>) = mappenddefault
instance Monoid a => Monoid (WithJSONWarnings a) where
    mempty = memptydefault
    mappend = (<>)

-- | Warning output from 'WarningParser'.
data JSONWarning = JSONUnrecognizedFields String [Key]
                 | JSONGeneralWarning !Text
    deriving Eq
instance Show JSONWarning where
  show = T.unpack . utf8BuilderToText . display
instance Display JSONWarning where
  display (JSONUnrecognizedFields obj [field]) =
    "Unrecognized field in " <> fromString obj <> ": " <> display (toText field)
  display (JSONUnrecognizedFields obj fields) =
    "Unrecognized fields in " <> fromString obj <> ": " <> display (T.intercalate ", " $ fmap toText fields)
  display (JSONGeneralWarning t) = display t

instance IsString JSONWarning where
  fromString = JSONGeneralWarning . T.pack

instance FromJSON (WithJSONWarnings StylesUpdate) where
  parseJSON v = noJSONWarnings <$> parseJSON v
