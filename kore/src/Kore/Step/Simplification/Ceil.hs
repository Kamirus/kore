{-|
Module      : Kore.Step.Simplification.Ceil
Description : Tools for Ceil pattern simplification.
Copyright   : (c) Runtime Verification, 2018
License     : NCSA
Maintainer  : virgil.serbanuta@runtimeverification.com
Stability   : experimental
Portability : portable
-}
module Kore.Step.Simplification.Ceil
    ( simplify
    , makeEvaluate
    , makeEvaluateTerm
    , simplifyEvaluated
    , Ceil (..)
    ) where

import Prelude.Kore

import qualified Data.Bifunctor as Bifunctor
import qualified Data.Foldable as Foldable
import qualified Data.Functor.Foldable as Recursive
import qualified Data.Map.Strict as Map

import qualified Kore.Attribute.Symbol as Attribute.Symbol
    ( isTotal
    )
import qualified Kore.Domain.Builtin as Domain
import qualified Kore.Internal.Condition as Condition
import Kore.Internal.Conditional
    ( Conditional (..)
    )
import qualified Kore.Internal.MultiAnd as MultiAnd
    ( make
    )
import qualified Kore.Internal.MultiOr as MultiOr
import Kore.Internal.OrCondition
    ( OrCondition
    )
import qualified Kore.Internal.OrCondition as OrCondition
import Kore.Internal.OrPattern
    ( OrPattern
    )
import qualified Kore.Internal.OrPattern as OrPattern
import Kore.Internal.Pattern
    ( Pattern
    )
import qualified Kore.Internal.Pattern as Pattern
import Kore.Internal.Predicate
    ( makeCeilPredicate_
    , makeTruePredicate_
    )
import qualified Kore.Internal.Predicate as Predicate
import Kore.Internal.SideCondition
    ( SideCondition
    )
import qualified Kore.Internal.SideCondition.SideCondition as SideCondition
    ( Representation
    )
import Kore.Internal.TermLike
import qualified Kore.Internal.TermLike as TermLike
import qualified Kore.Step.Function.Evaluator as Axiom
    ( evaluatePattern
    )
import qualified Kore.Step.Simplification.AndPredicates as And
import qualified Kore.Step.Simplification.Equals as Equals
import Kore.Step.Simplification.InjSimplifier
import qualified Kore.Step.Simplification.Not as Not
import Kore.Step.Simplification.Simplify as Simplifier
import Kore.TopBottom

import Kore.Unparser
    ( unparseToString
    )

{-| Simplify a 'Ceil' of 'OrPattern'.

A ceil(or) is equal to or(ceil). We also take into account that
* ceil(top) = top
* ceil(bottom) = bottom
* ceil leaves predicates and substitutions unchanged
* ceil transforms terms into predicates
-}
simplify
    :: (InternalVariable variable, MonadSimplify simplifier)
    => SideCondition variable
    -> Ceil Sort (OrPattern variable)
    -> simplifier (OrPattern variable)
simplify
    sideCondition
    Ceil { ceilChild = child }
  =
    simplifyEvaluated sideCondition child

{-| 'simplifyEvaluated' evaluates a ceil given its child, see 'simplify'
for details.
-}
{- TODO (virgil): Preserve pattern sorts under simplification.

One way to preserve the required sort annotations is to make 'simplifyEvaluated'
take an argument of type

> CofreeF (Ceil Sort) (Attribute.Pattern variable) (OrPattern variable)

instead of an 'OrPattern' argument. The type of 'makeEvaluate' may
be changed analogously. The 'Attribute.Pattern' annotation will eventually cache
information besides the pattern sort, which will make it even more useful to
carry around.

-}
simplifyEvaluated
    :: InternalVariable variable
    => MonadSimplify simplifier
    => SideCondition variable
    -> OrPattern variable
    -> simplifier (OrPattern variable)
simplifyEvaluated sideCondition child =
    MultiOr.flatten <$> traverse (makeEvaluate sideCondition) child

{-| Evaluates a ceil given its child as an Pattern, see 'simplify'
for details.
-}
makeEvaluate
    :: InternalVariable variable
    => MonadSimplify simplifier
    => SideCondition variable
    -> Pattern variable
    -> simplifier (OrPattern variable)
makeEvaluate sideCondition child
  | Pattern.isTop    child = return OrPattern.top
  | Pattern.isBottom child = return OrPattern.bottom
  | otherwise              = makeEvaluateNonBoolCeil sideCondition child

makeEvaluateNonBoolCeil
    :: InternalVariable variable
    => MonadSimplify simplifier
    => SideCondition variable
    -> Pattern variable
    -> simplifier (OrPattern variable)
makeEvaluateNonBoolCeil sideCondition patt@Conditional {term}
  | isTop term =
    return $ OrPattern.fromPattern
        patt {term = mkTop_} -- erase the term's sort.
  | otherwise = do
    termCeil <- makeEvaluateTerm sideCondition term
    result <-
        And.simplifyEvaluatedMultiPredicate
            sideCondition
            (MultiAnd.make
                [ MultiOr.make [Condition.eraseConditionalTerm patt]
                , termCeil
                ]
            )
    return (fmap Pattern.fromCondition result)

-- TODO: Ceil(function) should be an and of all the function's conditions, both
-- implicit and explicit.
{-| Evaluates the ceil of a TermLike, see 'simplify' for details.
-}
-- NOTE (hs-boot): Please update Ceil.hs-boot file when changing the
-- signature.
makeEvaluateTerm
    :: forall variable simplifier
    .  InternalVariable variable
    => MonadSimplify simplifier
    => SideCondition variable
    -> TermLike variable
    -> simplifier (OrCondition variable)
makeEvaluateTerm
    sideCondition
    term@(Recursive.project -> _ :< projected)
  =
    makeEvaluateTermWorker
  where
    makeEvaluateTermWorker
      | isTop term            = return OrCondition.top
      | isBottom term         = return OrCondition.bottom
      | isDefinedPattern term = return OrCondition.top

      | ApplySymbolF app <- projected
      , let Application { applicationSymbolOrAlias = patternHead } = app
      , let headAttributes = symbolAttributes patternHead
      , Attribute.Symbol.isTotal headAttributes = do
            let Application { applicationChildren = children } = app
            simplifiedChildren <- mapM (makeEvaluateTerm sideCondition) children
            let ceils = simplifiedChildren
            And.simplifyEvaluatedMultiPredicate
                sideCondition
                (MultiAnd.make ceils)

      | BuiltinF child <- projected =
        fromMaybe
            (makeSimplifiedCeil sideCondition Nothing term)
            (makeEvaluateBuiltin sideCondition child)

      | InjF inj <- projected = do
        InjSimplifier { evaluateCeilInj } <- askInjSimplifier
        (makeEvaluateTerm sideCondition . ceilChild . evaluateCeilInj)
            Ceil
                { ceilResultSort = termLikeSort term -- sort is irrelevant
                , ceilOperandSort = termLikeSort term
                , ceilChild = inj
                }

      | otherwise = do
        evaluation <- Axiom.evaluatePattern
            sideCondition
            Conditional
                { term = ()
                , predicate = makeTruePredicate_
                , substitution = mempty
                }
            (mkCeil_ term)
            (\maybeCondition ->
                OrPattern.fromPatterns
                . map Pattern.fromCondition
                . OrCondition.toConditions
                <$> makeSimplifiedCeil sideCondition maybeCondition term
            )
        return (fmap toCondition evaluation)

    toCondition Conditional {term = Top_ _, predicate, substitution} =
        Conditional {term = (), predicate, substitution}
    toCondition patt =
        error
            (  "Ceil simplification is expected to result ai a predicate, but"
            ++ " got (" ++ show patt ++ ")."
            ++ " The most likely cases are: evaluating predicate symbols, "
            ++ " and predicate symbols are currently unrecognized as such, "
            ++ "and programming errors."
            )

{-| Evaluates the ceil of a domain value.
-}
makeEvaluateBuiltin
    :: forall variable simplifier
    .  InternalVariable variable
    => MonadSimplify simplifier
    => SideCondition variable
    -> Builtin (TermLike variable)
    -> Maybe (simplifier (OrCondition variable))
makeEvaluateBuiltin
    sideCondition
    (Domain.BuiltinMap Domain.InternalAc
        {builtinAcChild}
    )
  =
    makeEvaluateNormalizedAc
        sideCondition
        (Domain.unwrapAc builtinAcChild)
makeEvaluateBuiltin sideCondition (Domain.BuiltinList l) = Just $ do
    children <- mapM (makeEvaluateTerm sideCondition) (Foldable.toList l)
    let
        ceils :: [OrCondition variable]
        ceils = children
    And.simplifyEvaluatedMultiPredicate sideCondition (MultiAnd.make ceils)
makeEvaluateBuiltin
    sideCondition
    (Domain.BuiltinSet Domain.InternalAc
        {builtinAcChild}
    )
  =
    makeEvaluateNormalizedAc
        sideCondition
        (Domain.unwrapAc builtinAcChild)
makeEvaluateBuiltin _ (Domain.BuiltinBool _) = Just $ return OrCondition.top
makeEvaluateBuiltin _ (Domain.BuiltinInt _) = Just $ return OrCondition.top
makeEvaluateBuiltin _ (Domain.BuiltinString _) = Just $ return OrCondition.top

makeEvaluateNormalizedAc
    :: forall normalized variable simplifier
    .   ( InternalVariable variable
        , MonadSimplify simplifier
        , Traversable (Domain.Value normalized)
        , Domain.AcWrapper normalized
        )
    =>  SideCondition variable
    ->  Domain.NormalizedAc
            normalized
            (TermLike Concrete)
            (TermLike variable)
    -> Maybe (simplifier (OrCondition variable))
makeEvaluateNormalizedAc
    sideCondition
    Domain.NormalizedAc
        { elementsWithVariables
        , concreteElements
        , opaque = []
        }
  = TermLike.assertConstructorLikeKeys concreteKeys . Just $ do
    variableKeyConditions <- mapM (makeEvaluateTerm sideCondition) variableKeys
    variableValueConditions <- evaluateValues variableValues
    concreteValueConditions <- evaluateValues concreteValues


    elementsWithVariablesDistinct <-
        evaluateDistinct variableKeys concreteKeys
    let allConditions :: [OrCondition variable]
        allConditions =
            concreteValueConditions
            ++ variableValueConditions
            ++ variableKeyConditions
            ++ elementsWithVariablesDistinct
    And.simplifyEvaluatedMultiPredicate
        sideCondition
        (MultiAnd.make allConditions)
  where
    concreteElementsList
        ::  [   ( TermLike variable
                , Domain.Value normalized (TermLike variable)
                )
            ]
    concreteElementsList =
        map
            (Bifunctor.first TermLike.fromConcrete)
            (Map.toList concreteElements)
    (variableKeys, variableValues) =
        unzip (Domain.unwrapElement <$> elementsWithVariables)
    (concreteKeys, concreteValues) = unzip concreteElementsList

    evaluateDistinct
        :: [TermLike variable]
        -> [TermLike variable]
        -> simplifier [OrCondition variable]
    evaluateDistinct [] _ = return []
    evaluateDistinct (variableTerm : variableTerms) concreteTerms = do
        equalities <-
            mapM
                (flip
                    (Equals.makeEvaluateTermsToPredicate variableTerm)
                    sideCondition
                )
                -- TODO(virgil): consider eliminating these repeated
                -- concatenations.
                (variableTerms ++ concreteTerms)
        negations <- mapM Not.simplifyEvaluatedPredicate equalities

        remainingConditions <-
            evaluateDistinct variableTerms concreteTerms
        return (negations ++ remainingConditions)

    evaluateValues
        :: [Domain.Value normalized (TermLike variable)]
        -> simplifier [OrCondition variable]
    evaluateValues elements = do
        wrapped <- evaluateWrappers elements
        let unwrapped = map Foldable.toList wrapped
        return (concat unwrapped)
      where
        evaluateWrapper
            :: Domain.Value normalized (TermLike variable)
            -> simplifier (Domain.Value normalized (OrCondition variable))
        evaluateWrapper = traverse (makeEvaluateTerm sideCondition)

        evaluateWrappers
            :: [Domain.Value normalized (TermLike variable)]
            -> simplifier [Domain.Value normalized (OrCondition variable)]
        evaluateWrappers = traverse evaluateWrapper

makeEvaluateNormalizedAc
    sideCondition
    Domain.NormalizedAc
        { elementsWithVariables = []
        , concreteElements
        , opaque = [opaqueAc]
        }
  | Map.null concreteElements = Just $ makeEvaluateTerm sideCondition opaqueAc
makeEvaluateNormalizedAc _  _ = Nothing

{-| This handles the case when we can't simplify a term's ceil.

It returns the ceil of that term.

When the term's ceil implies the ceils of its subterms, this also @and@s
the subterms' simplified ceils to the result. This is needed because the
SMT solver can't infer a subterm's ceil from a term's ceil, so we
have to provide that information.

As an example, if we call @makeSimplifiedCeil@ for @f(g(x))@, and we don't
know how to simplify @ceil(g(x))@, the return value will be
@and(ceil(f(g(x))), ceil(g(x)))@.

-}
makeSimplifiedCeil
    :: (InternalVariable variable, MonadSimplify simplifier)
    => SideCondition variable
    -> Maybe SideCondition.Representation
    -> TermLike variable
    -> simplifier (OrCondition variable)
makeSimplifiedCeil
    sideCondition
    maybeCurrentCondition
    termLike@(Recursive.project -> _ :< termLikeF)
  = do
    childCeils <- if needsChildCeils
        then mapM (makeEvaluateTerm sideCondition) (Foldable.toList termLikeF)
        else return []
    And.simplifyEvaluatedMultiPredicate
        sideCondition
        (MultiAnd.make (unsimplified : childCeils))
  where
    needsChildCeils = case termLikeF of
        ApplyAliasF _ -> False
        EvaluatedF  _ -> False
        EndiannessF _ -> True
        SignednessF _ -> True
        AndF _ -> True
        ApplySymbolF _ -> True
        InjF _ -> True
        CeilF _ -> unexpectedError
        EqualsF _ -> unexpectedError
        ExistsF _ -> False
        IffF _ -> False
        ImpliesF _ -> False
        InF _ -> False
        NotF _ -> False
        BottomF _ -> unexpectedError
        BuiltinF (Domain.BuiltinMap _) -> True
        BuiltinF (Domain.BuiltinList _) -> True
        BuiltinF (Domain.BuiltinSet _) -> True
        BuiltinF (Domain.BuiltinInt _) -> unexpectedError
        BuiltinF (Domain.BuiltinBool _) -> unexpectedError
        BuiltinF (Domain.BuiltinString _) -> unexpectedError
        DomainValueF _ -> True
        FloorF _ -> False
        ForallF _ -> False
        InhabitantF _ -> False
        MuF _ -> False
        NuF _ -> False
        NextF _ -> True
        OrF _ -> False
        RewritesF _ -> False
        TopF _ -> unexpectedError
        StringLiteralF _ -> unexpectedError
        InternalBytesF _ -> unexpectedError
        VariableF _ -> False

    unsimplified =
        OrCondition.fromCondition
        . Condition.fromPredicate
        . Predicate.markSimplifiedMaybeConditional maybeCurrentCondition
        . makeCeilPredicate_
        $ termLike

    unexpectedError =
        error ("Unexpected term type: " ++ unparseToString termLike)
