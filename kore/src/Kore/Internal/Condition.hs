{- |
Copyright   : (c) Runtime Verification, 2018
License     : NCSA

-}
module Kore.Internal.Condition
    ( Condition
    , isSimplified
    , simplifiedAttribute
    , forgetSimplified
    , Conditional.markPredicateSimplified
    , Conditional.markPredicateSimplifiedConditional
    , Conditional.setPredicateSimplified
    , eraseConditionalTerm
    , top
    , bottom
    , topCondition
    , bottomCondition
    , fromPattern
    , Conditional.fromPredicate
    , Conditional.fromSingleSubstitution
    , Conditional.fromSubstitution
    , toPredicate
    , hasFreeVariable
    , coerceSort
    , conditionSort
    , Kore.Internal.Condition.mapVariables
    , fromNormalizationSimplified
    -- * Re-exports
    , Conditional (..)
    , Conditional.andCondition
    ) where

import Prelude.Kore

import Kore.Attribute.Pattern.FreeVariables
    ( freeVariables
    , isFreeVariable
    )
import qualified Kore.Attribute.Pattern.Simplified as Attribute
    ( Simplified
    )
import Kore.Internal.Conditional
    ( Conditional (..)
    )
import qualified Kore.Internal.Conditional as Conditional
import Kore.Internal.Predicate
    ( Predicate
    )
import qualified Kore.Internal.Predicate as Predicate
import qualified Kore.Internal.SideCondition.SideCondition as SideCondition
    ( Representation
    )
import Kore.Internal.Substitution
    ( Normalization (..)
    )
import qualified Kore.Internal.Substitution as Substitution
import Kore.Internal.TermLike
    ( TermLike
    )
import qualified Kore.Internal.TermLike as TermLike
    ( simplifiedAttribute
    )
import Kore.Internal.Variable
import Kore.Syntax
import Kore.Variables.Fresh
    ( FreshPartialOrd
    )
import Kore.Variables.UnifiedVariable
    ( UnifiedVariable
    )

-- | A predicate and substitution without an accompanying term.
type Condition variable = Conditional variable ()

isSimplified :: SideCondition.Representation -> Condition variable -> Bool
isSimplified sideCondition Conditional {term = (), predicate, substitution} =
    Predicate.isSimplified sideCondition predicate
    && Substitution.isSimplified sideCondition substitution

simplifiedAttribute :: Condition variable -> Attribute.Simplified
simplifiedAttribute Conditional {term = (), predicate, substitution} =
    Predicate.simplifiedAttribute predicate
    <> Substitution.simplifiedAttribute substitution

forgetSimplified
    :: InternalVariable variable
    => Condition variable -> Condition variable
forgetSimplified Conditional { term = (), predicate, substitution } =
    Conditional
        { term = ()
        , predicate = Predicate.forgetSimplified predicate
        , substitution = Substitution.forgetSimplified substitution
        }

-- | Erase the @Conditional@ 'term' to yield a 'Condition'.
eraseConditionalTerm
    :: Conditional variable child
    -> Condition variable
eraseConditionalTerm = Conditional.withoutTerm

top :: InternalVariable variable => Condition variable
top =
    Conditional
        { term = ()
        , predicate = Predicate.makeTruePredicate_
        , substitution = mempty
        }

bottom :: InternalVariable variable => Condition variable
bottom =
    Conditional
        { term = ()
        , predicate = Predicate.makeFalsePredicate_
        , substitution = mempty
        }

topCondition :: InternalVariable variable => Condition variable
topCondition = top

bottomCondition :: InternalVariable variable => Condition variable
bottomCondition = bottom

hasFreeVariable
    :: InternalVariable variable
    => UnifiedVariable variable
    -> Condition variable
    -> Bool
hasFreeVariable variable = isFreeVariable variable . freeVariables

{- | Extract the set of free set variables from a predicate and substitution.

    See also: 'Predicate.freeSetVariables'.
-}

{- | Transform a predicate and substitution into a predicate only.

@toPredicate@ is intended for generalizing the 'Predicate' and 'Substitution' of
a 'PredicateSubstition' into only a 'Predicate'.

See also: 'Substitution.toPredicate'.

-}
toPredicate
    :: InternalVariable variable
    => Condition variable
    -> Predicate variable
toPredicate = from

mapVariables
    :: (Ord variable1, FreshPartialOrd variable2, SortedVariable variable2)
    => (ElementVariable variable1 -> ElementVariable variable2)
    -> (SetVariable variable1 -> SetVariable variable2)
    -> Condition variable1
    -> Condition variable2
mapVariables = Conditional.mapVariables (\_ _ () -> ())

{- | Create a new 'Condition' from the 'Normalization' of a substitution.

The 'normalized' part becomes the normalized 'substitution', while the
'denormalized' part is converted into an ordinary 'predicate'.

 -}
fromNormalizationSimplified
    :: InternalVariable variable
    => Normalization variable
    -> Condition variable
fromNormalizationSimplified Normalization { normalized, denormalized } =
    predicate' <> substitution'
  where
    predicate' =
        Conditional.fromPredicate
        . markSimplifiedIfChildrenSimplified denormalized
        . Substitution.toPredicate
        $ Substitution.wrap denormalized
    substitution' =
        Conditional.fromSubstitution
        $ Substitution.unsafeWrap normalized
    markSimplifiedIfChildrenSimplified childrenList result =
        Predicate.setSimplified childrenSimplified result
      where
        childrenSimplified =
            foldMap (TermLike.simplifiedAttribute . dropVariable) childrenList

        dropVariable
            :: (UnifiedVariable variable, TermLike variable)
            -> TermLike variable
        dropVariable = snd

conditionSort :: Condition variable -> Sort
conditionSort Conditional {term = (), predicate} =
    Predicate.predicateSort predicate

coerceSort
    :: (HasCallStack, InternalVariable variable)
    => Sort -> Condition variable -> Condition variable
coerceSort
    sort
    Conditional {term = (), predicate, substitution}
  =
    Conditional
        { term = ()
        , predicate = Predicate.coerceSort sort predicate
        , substitution
        }
