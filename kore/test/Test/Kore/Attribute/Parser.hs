module Test.Kore.Attribute.Parser
    ( module Kore.Attribute.Parser
    , expectSuccess
    , expectFailure
    ) where

import Prelude.Kore

import Test.Tasty.HUnit

import Kore.Attribute.Attributes
    ( Attributes (..)
    )
import Kore.Attribute.Parser

expectSuccess
    :: (Eq attr, Eq e, Show attr, Show e)
    => attr
    -> Either e attr
    -> Assertion
expectSuccess assoc =
    assertEqual "expected parsed attribute" (Right assoc)

expectFailure :: HasCallStack => Either e attr -> Assertion
expectFailure = assertBool "expected parse failure" . isLeft
