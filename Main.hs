{-# LANGUAGE MultiWayIf        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE DeriveFunctor     #-}

import           Control.Applicative
import qualified Data.ByteString.Char8    as BS
import qualified Data.Text                as T

import           Data.JStream.TokenParser

data ParseResult v =  MoreData (Parser v, BS.ByteString -> TokenParser)
                | Failed String
                | Done TokenParser
                | Yield v (ParseResult v)
                | Unexpected Element TokenParser


instance Functor ParseResult where
  fmap f (MoreData (np, ntok)) = MoreData (fmap f np, ntok)
  fmap _ (Failed err) = Failed err
  fmap _ (Done tp) = Done tp
  fmap f (Yield v np) = Yield (f v) (fmap f np)
  fmap _ (Unexpected el tp) = Unexpected el tp

instance Functor Parser where
  fmap f (Parser p) = Parser $ \d -> fmap f (p d)

instance Applicative Parser where
  pure x = Parser $ \tok -> Yield x (callParse ignoreVal tok)
  -- (<*>) m1 m2 = Parser $ \tok ->
  --
  --     where


newtype Parser a = Parser {
    callParse :: TokenParser -> ParseResult a
}

-- Special parser for key-value pairs
newtype KeyParser a = KeyParser {
  callKeyParse :: Parser a
} deriving (Functor)

array :: Parser a -> Parser a
array valparse = Parser $ \tp ->
  case tp of
    (PartialResult ArrayBegin ntp _) -> arrcontent (callParse valparse ntp)
    (PartialResult el ntp _) -> Unexpected el ntp
    (TokMoreData ntok _) -> MoreData (array valparse, ntok)
    (TokFailed _) -> Failed "Array - token failed"
  where
    arrcontent (Done ntp) = arrcontent (callParse valparse ntp) -- Reset to next value
    arrcontent (MoreData (Parser np, ntp)) = MoreData (Parser (arrcontent . np), ntp)
    arrcontent (Yield v np) = Yield v (arrcontent np)
    arrcontent (Failed err) = Failed err
    arrcontent (Unexpected ArrayEnd ntp) = Done ntp
    arrcontent (Unexpected el _) = Failed ("Array - unexpected: " ++ show el)

object :: KeyParser a -> Parser a
object valparse = Parser $ \tp ->
  case tp of
    (PartialResult ObjectBegin ntp _) -> objcontent (callParse (callKeyParse valparse) ntp)
    (PartialResult el ntp _) -> Unexpected el ntp
    (TokMoreData ntok _) -> MoreData (object valparse, ntok)
    (TokFailed _) -> Failed "Object - token failed"
  where
    objcontent (Done ntp) = objcontent (callParse (callKeyParse valparse) ntp) -- Reset to next value
    objcontent (MoreData (Parser np, ntok)) = MoreData (Parser (objcontent . np), ntok)
    objcontent (Yield v np) = Yield v (objcontent np)
    objcontent (Failed err) = Failed err
    objcontent (Unexpected ObjectEnd ntp) = Done ntp
    objcontent (Unexpected el _) = Failed ("Object - unexpected: " ++ show el)

keyValue :: Parser a -> KeyParser (T.Text, a)
keyValue valparse = KeyParser $ Parser $ keyValue_'
  where
    keyValue_' (TokFailed _) = Failed "KeyValue - token failed"
    keyValue_' (TokMoreData ntok _) = MoreData (Parser keyValue_', ntok)
    keyValue_' (PartialResult (ObjectKey key) ntok _) = (key,) <$> callParse valparse ntok
    keyValue_' (PartialResult el ntok _) = Unexpected el ntok

objKey :: T.Text -> Parser a -> KeyParser a
objKey name valparse = KeyParser $ Parser $ \tok -> filterKey $ callParse (callKeyParse (keyValue valparse)) tok
  where
    filterKey :: ParseResult (T.Text, a) -> ParseResult a
    filterKey (Done ntp) = Done ntp
    filterKey (MoreData (Parser np, ntok)) = MoreData (Parser (filterKey . np), ntok)
    filterKey (Yield (ykey, v) np)
      | ykey == name = Yield v (filterKey np)
      | otherwise = filterKey np
    filterKey (Failed err) = Failed err
    filterKey (Unexpected el ntp) = Unexpected el ntp

-- | Parses underlying values and generates a JValue
value :: Parser JValue
value = Parser value'
  where
    value' (TokFailed _) = Failed "Value - token failed"
    value' (TokMoreData ntok _) = MoreData (Parser value', ntok)
    value' (PartialResult (JValue val) ntok _) = Yield val (Done ntok)
    value' tok@(PartialResult ArrayBegin _ _) = JArray <$> callParse (getYields (array value)) tok
    value' (PartialResult el ntok _) = Unexpected el ntok

-- | Continue parsing, thus skipping any value.
ignoreVal :: Parser a
ignoreVal = Parser $ handleTok 0
  where
    handleTok :: Int -> TokenParser -> ParseResult a
    handleTok _ (TokFailed _) = Failed "Token error"
    handleTok level (TokMoreData ntok _) = MoreData (Parser (handleTok level), ntok)

    handleTok 0 (PartialResult (JValue _) ntok _) = Done ntok
    handleTok 0 (PartialResult (ObjectKey _) ntok _) = Done ntok
    handleTok level (PartialResult (JValue _) ntok _) = handleTok level ntok
    handleTok level (PartialResult (ObjectKey _) ntok _) = handleTok level ntok

    handleTok 1 (PartialResult elm ntok _)
      | elm == ArrayEnd || elm == ObjectEnd = Done ntok
    handleTok level (PartialResult elm ntok _)
      | elm == ArrayBegin || elm == ObjectBegin = handleTok (level + 1) ntok
      | elm == ArrayEnd || elm == ObjectEnd = handleTok (level - 1) ntok
    handleTok _ _ = Failed "Unexpected "

-- | Fetch yields of a function and return them as list
getYields :: Parser a -> Parser [a]
getYields f = Parser $ \ntok -> loop [] (callParse f ntok)
  where
    loop acc (Done ntp) = Yield (reverse acc) (Done ntp)
    loop acc (MoreData (Parser np, ntok)) = MoreData (Parser (loop acc . np), ntok)
    loop acc (Yield v np) = loop (v:acc) np
    loop _ (Failed err) = Failed err
    loop _ (Unexpected el _) = Failed ("getYields - unexpected: " ++ show el)

execIt :: Show a => [BS.ByteString] -> Parser a -> IO ()
execIt input parser = loop (tail input) $ callParse parser (tokenParser $ head input)
  where
    loop [] (MoreData _) = putStrLn "Out of data - "
    loop _ (Failed err) = putStrLn $ "Failed: " ++ err
    loop _ (Done (PartialResult _ _ rest)) = putStrLn $ "Done: "  ++ show rest
    loop _ (Done (TokFailed rest)) = putStrLn $ "Done: " ++ show rest
    loop _ (Done (TokMoreData _ bl)) = putStrLn $ "Done md - more data: " ++ show bl
    loop (dta:rest) (MoreData (Parser np, ntok)) = loop rest $ np (ntok dta)
    loop dta (Yield item np) = do
        putStrLn $ "Got: " ++ show item
        loop dta np
    loop _ (Unexpected _ _) = putStrLn "Unexpected - failed"

testParser = object (objKey "ondra" (pure "test"))

main :: IO ()
main = do
  -- let test = ["[1,2", "2,3,\"", "ond\\\"ra\"","t", "rue,fal", "se,[null]", "{\"ondra\":\"martin\", \"x\":5}", "]"]
  -- let test = ["[[1, 2], [3, 4 ], [5, \"ondra\", true, false, null] ] "]
  let test = ["{\"ondra\":12, \"ma", "rtin\":true}   \"a "]
  execIt test testParser
  return ()
