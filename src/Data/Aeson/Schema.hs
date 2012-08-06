{-# LANGUAGE OverloadedStrings, FlexibleInstances #-}

module Data.Aeson.Schema
  ( Schema (..)
  , empty
  , Fix (..)
  , followReferences
  , validate
  ) where

import Prelude hiding (foldr, length)
import Data.Maybe (fromMaybe, maybe)
import Data.Foldable (Foldable (..), toList)
import Data.Traversable (traverse)
import Data.List (concat)
import Data.Function (fix)
import Data.Functor ((<$>))
import Data.Ratio
import Control.Applicative ((<*>))
import Control.Monad ((=<<), mapM, msum)
import Data.Aeson (Value (..), (.:?), (.!=), FromJSON (..))
import Data.Aeson.Types (Parser (..), emptyObject, emptyArray)
import qualified Data.Aeson as A
import Data.Aeson.Types (parse)
import qualified Data.Vector as V
import qualified Data.HashMap.Strict as H
import qualified Data.Map as M
import Data.Text (Text (..), unpack, length)
import Data.Attoparsec.Number (Number (..))

import Data.Aeson.Schema.Choice

type Map a = H.HashMap Text a

data Schema ref = Schema
  { schemaType :: [Choice2 String (Schema ref)]
  , schemaProperties :: Map (Schema ref)
  , schemaPatternProperties :: Map (Schema ref)
  , schemaAdditionalProperties :: Choice3 String Bool (Schema ref)
  , schemaItems :: Maybe (Choice3 String (Schema ref) [Schema ref])
  , schemaAdditionalItems :: Choice3 String Bool (Schema ref)
  , schemaRequired :: Bool
  , schemaDependencies :: Map (Choice2 [String] (Schema ref))
  , schemaMinimum :: Maybe Number
  , schemaMaximum :: Maybe Number
  , schemaExclusiveMinimum :: Bool
  , schemaExclusiveMaximum :: Bool
  , schemaMinItems :: Int
  , schemaMaxItems :: Maybe Int
  , schemaUniqueItems :: Bool
  , schemaPattern :: Maybe String
  , schemaMinLength :: Int
  , schemaMaxLength :: Maybe Int
  , schemaEnum :: Maybe [Value]
  , schemaEnumDescriptions :: Maybe [String]
  , schemaDefault :: Maybe Value
  , schemaTitle :: Maybe String
  , schemaDescription :: Maybe String
  , schemaFormat :: Maybe String
  , schemaDivisibleBy :: Maybe Number
  , schemaDisallow :: [Choice2 String (Schema ref)]
  , schemaExtends :: [Schema ref]
  , schemaId :: Maybe String
  , schemaDRef :: Maybe ref -- ^ $ref
  , schemaDSchema :: Maybe String -- ^ $schema
  } deriving (Eq, Show)

instance Functor Schema where
  fmap f s = s
    { schemaType = choice2 id (fmap f) <$> schemaType s
    , schemaProperties = fmap f <$> schemaProperties s
    , schemaPatternProperties = fmap f <$> schemaPatternProperties s
    , schemaAdditionalProperties = choice3 id id (fmap f) (schemaAdditionalProperties s)
    , schemaItems = choice3 id (fmap f) (fmap $ fmap f) <$> schemaItems s
    , schemaAdditionalItems = choice3 id id (fmap f) (schemaAdditionalItems s)
    , schemaDependencies = choice2 id (fmap f) <$> schemaDependencies s
    , schemaDisallow = choice2 id (fmap f) <$> schemaDisallow s
    , schemaExtends = fmap f <$> schemaExtends s
    , schemaDRef = f <$> schemaDRef s
    }

instance Foldable Schema where
  foldr f start s = ffoldr (ffoldr f) (choice2of2s $ schemaType s)
                  . ffoldr (ffoldr f) (schemaProperties s)
                  . ffoldr (ffoldr f) (schemaPatternProperties s)
                  . foldChoice3of3 (ffoldr f) (schemaAdditionalProperties s)
                  . ffoldr (\items -> foldChoice2of3 (ffoldr f) items . foldChoice3of3 (ffoldr $ ffoldr f) items) (schemaItems s)
                  . foldChoice3of3 (ffoldr f) (schemaAdditionalItems s)
                  . ffoldr (ffoldr f) (choice2of2s $ toList $ schemaDependencies s)
                  . ffoldr (ffoldr f) (choice2of2s $ schemaDisallow s)
                  . ffoldr (ffoldr f) (schemaExtends s)
                  . ffoldr f (schemaDRef s)
                  $ start
    where
      ffoldr :: (Foldable t) => (a -> b -> b) -> t a -> b -> b
      ffoldr g = flip $ foldr g
      foldChoice2of3 :: (a -> b -> b) -> Choice3 x a y -> b -> b
      foldChoice2of3 g (Choice2of3 c) = g c
      foldChoice2of3 _ _ = id
      foldChoice3of3 :: (a -> b -> b) -> Choice3 x y a -> b -> b
      foldChoice3of3 g (Choice3of3 c) = g c
      foldChoice3of3 _ _ = id

empty :: Schema ref
empty = Schema
  { schemaType = []
  , schemaProperties = H.empty
  , schemaPatternProperties = H.empty
  , schemaAdditionalProperties = Choice2of3 True
  , schemaItems = Nothing
  , schemaAdditionalItems = Choice2of3 True
  , schemaRequired = False
  , schemaDependencies = H.empty
  , schemaMinimum = Nothing
  , schemaMaximum = Nothing
  , schemaExclusiveMinimum = False
  , schemaExclusiveMaximum = False
  , schemaMinItems = 0
  , schemaMaxItems = Nothing
  , schemaUniqueItems = False
  , schemaPattern = Nothing
  , schemaMinLength = 0
  , schemaMaxLength = Nothing
  , schemaEnum = Nothing
  , schemaEnumDescriptions = Nothing
  , schemaDefault = Nothing
  , schemaTitle = Nothing
  , schemaDescription = Nothing
  , schemaFormat = Nothing
  , schemaDivisibleBy = Nothing
  , schemaDisallow = []
  , schemaExtends = []
  , schemaId = Nothing
  , schemaDRef = Nothing
  , schemaDSchema = Nothing
  }

newtype Fix a = Fix (a (Fix a))

instance FromJSON (Schema String) where
  parseJSON (Object o) =
    Schema <$> (parseSingleOrArray =<< parseFieldDefault "type" "any")
           <*> parseFieldDefault "properties" emptyObject
           <*> parseFieldDefault "patternProperties" emptyObject
           <*> (parseField "additionalProperties" .!= Choice2of3 True)
           <*> parseField "items"
           <*> (parseField "additionalItems" .!= Choice2of3 True)
           <*> parseFieldDefault "required" (Bool False)
           <*> (traverse parseDependency =<< parseFieldDefault "dependencies" emptyObject)
           <*> parseField "minimum"
           <*> parseField "maximum"
           <*> parseFieldDefault "exclusiveMinimum" (Bool False)
           <*> parseFieldDefault "exclusiveMaximum" (Bool False)
           <*> parseFieldDefault "minItems" (Number $ fromInteger 0)
           <*> parseField "maxItems"
           <*> parseFieldDefault "uniqueItems" (Bool False)
           <*> parseField "pattern"
           <*> parseFieldDefault "minLength" (Number $ fromInteger 0)
           <*> parseField "maxLength"
           <*> parseField "enum"
           <*> parseField "enumDescriptions"
           <*> parseField "default"
           <*> parseField "title"
           <*> parseField "description"
           <*> parseField "format"
           <*> parseField "divisibleBy"
           <*> (parseSingleOrArray =<< parseFieldDefault "disallow" emptyArray)
           <*> ((maybe (return Nothing) (fmap Just . parseSingleOrArray) =<< parseField "extends") .!= [])
           <*> parseField "id"
           <*> parseField "$ref"
           <*> parseField "$schema"
      where
        parseField :: (FromJSON a) => Text -> Parser (Maybe a)
        parseField name = o .:? name
        parseFieldDefault :: (FromJSON a) => Text -> Value -> Parser a
        parseFieldDefault name value = parseJSON =<< parseField name .!= value

        parseDependency (String s) = return $ Choice1of2 [unpack s]
        parseDependency o = parseJSON o
  parseJSON _ = fail "a schema must be a JSON object"

singleOrArray :: (Value -> Parser a) -> Value -> Parser [a]
singleOrArray p (Array a) = mapM p (V.toList a)
singleOrArray p v = (:[]) <$> p v

parseSingleOrArray :: (FromJSON a) => Value -> Parser [a]
parseSingleOrArray = singleOrArray parseJSON

followReferences :: (Ord k, Functor f) => M.Map k (f k) -> M.Map k (f (Fix f))
followReferences input = fix $ \output -> fmap (Fix . (M.!) output) <$> input

validate :: Schema String -> Value -> Maybe String
validate schema val = case parse (validateP schema) val of
  A.Error e -> Just e
  A.Success _ -> Nothing

validateP :: Schema String -> Value -> Parser ()
validateP schema val = do
  msum $ map validateType (schemaType schema)
  where
    validateType :: Choice2 String (Schema String) -> Parser ()
    validateType (Choice1of2 t) = case t of
      "string" -> case val of
        String s -> do
          let checkMinLength l = assert (length s >= l) $ "length of string must be at least " ++ show l
          checkMinLength $ schemaMinLength schema
          let checkMaxLength l = assert (length s <= l) $ "length of string must be at most " ++ show l
          maybeCheck checkMaxLength (schemaMaxLength schema)
        _ -> fail "not a string"
      "number" -> case val of
        Number n -> do
          let checkMinimum m = if schemaExclusiveMinimum schema
                               then assert (n > m)  $ "number must be greater than " ++ show m
                               else assert (n >= m) $ "number must be greater than or equal " ++ show m
          maybeCheck checkMinimum $ schemaMinimum schema
          let checkMaximum m = if schemaExclusiveMaximum schema
                               then assert (n < m)  $ "number must be less than " ++ show m
                               else assert (n <= m) $ "number must be less than or equal " ++ show m
          maybeCheck checkMaximum $ schemaMaximum schema
          let checkDivisibleBy devisor = assert (n `isDivisibleBy` devisor) $ "number must be devisible by " ++ show devisor
          maybeCheck checkDivisibleBy $ schemaDivisibleBy schema
        _ -> fail "not a number"
      "integer" -> case val of
        Number (I _) -> validateType (Choice1of2 "number")
        _ -> fail "not an integer"
      "boolean" -> fail "not implemented"
      "object" -> fail "not implemented"
      "array" -> fail "not implemented"
      "null" -> fail "not implemented"
      "any" -> fail "not implemented"
      _ -> fail $ "unknown type " ++ t
    validateType _ = fail "not implemented"

    isDivisibleBy :: Number -> Number -> Bool
    isDivisibleBy (I i) (I j) = i `mod` j == 0
    isDivisibleBy a b = a == fromInteger 0 || denominator (approxRational (a / b) epsilon) `elem` [-1,1]
      where epsilon = D $ 10 ** (-10)

    assert :: Bool -> String -> Parser ()
    assert True _ = return ()
    assert False e = fail e

    maybeCheck :: (a -> Parser ()) -> Maybe a -> Parser ()
    maybeCheck p (Just a) = p a
    maybeCheck _ _ = return ()
