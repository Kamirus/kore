module Data.Kore.ASTVerifier.PatternVerifier (verifyPattern) where

import           Data.Kore.AST
import           Data.Kore.ASTVerifier.Error
import           Data.Kore.ASTVerifier.Resolvers
import           Data.Kore.ASTVerifier.SortVerifier
import           Data.Kore.Error
import           Data.Kore.ImplicitDefinitions
import           Data.Kore.IndexedModule.IndexedModule
import           Data.Kore.Unparser.Unparse

import           Control.Monad                         (zipWithM_)
import qualified Data.Map                              as Map
import qualified Data.Set                              as Set
import           Data.Typeable                         (Typeable)

data DeclaredVariables = DeclaredVariables
    { objectDeclaredVariables :: !(Map.Map (Id Object) (Variable Object))
    , metaDeclaredVariables   :: !(Map.Map (Id Meta) (Variable Meta))
    }

emptyDeclaredVariables :: DeclaredVariables
emptyDeclaredVariables = DeclaredVariables
    { objectDeclaredVariables = Map.empty
    , metaDeclaredVariables = Map.empty
    }

data ApplicationSorts a = ApplicationSorts
    { applicationSortsOperands :: ![Sort a]
    , applicationSortsReturn   :: !(Sort a)
    }

data VerifyHelpers a = VerifyHelpers
    { verifyHelpersFindSort
        :: !(Id a -> Either (Error VerifyError) (SortDescription a))
    , verifyHelpersLookupAliasDeclaration
        :: !(Id a -> Maybe (SentenceAlias a))
    , verifyHelpersLookupSymbolDeclaration
        :: !(Id a -> Maybe (SentenceSymbol a))
    , verifyHelpersFindDeclaredVariables
        :: !(Id a -> Maybe (Variable a))
    }

metaVerifyHelpers :: IndexedModule -> DeclaredVariables -> VerifyHelpers Meta
metaVerifyHelpers indexedModule declaredVariables =
    VerifyHelpers
        { verifyHelpersFindSort =
            resolveSort indexedModuleMetaSortDescriptions indexedModule
        , verifyHelpersLookupAliasDeclaration =
            resolveThing indexedModuleMetaAliasSentences indexedModule
        , verifyHelpersLookupSymbolDeclaration =
            resolveThing indexedModuleMetaSymbolSentences indexedModule
        , verifyHelpersFindDeclaredVariables =
            flip Map.lookup (metaDeclaredVariables declaredVariables)
        }

objectVerifyHelpers
    :: IndexedModule -> DeclaredVariables -> VerifyHelpers Object
objectVerifyHelpers indexedModule declaredVariables =
    VerifyHelpers
        { verifyHelpersFindSort =
            resolveSort indexedModuleObjectSortDescriptions indexedModule
        , verifyHelpersLookupAliasDeclaration =
            resolveThing indexedModuleObjectAliasSentences indexedModule
        , verifyHelpersLookupSymbolDeclaration =
            resolveThing indexedModuleObjectSymbolSentences indexedModule
        , verifyHelpersFindDeclaredVariables =
            flip Map.lookup (objectDeclaredVariables declaredVariables)
        }

addDeclaredVariable :: UnifiedVariable -> DeclaredVariables -> DeclaredVariables
addDeclaredVariable
    (MetaVariable variable)
    variables@DeclaredVariables{ metaDeclaredVariables = variablesDict }
  =
    variables
        { metaDeclaredVariables =
            Map.insert (variableName variable) variable variablesDict
        }
addDeclaredVariable
    (ObjectVariable variable)
    variables@DeclaredVariables{ objectDeclaredVariables = variablesDict }
  =
    variables
        { objectDeclaredVariables =
            Map.insert (variableName variable) variable variablesDict
        }

verifyPattern
    :: UnifiedPattern
    -> Maybe UnifiedSort
    -> IndexedModule
    -> Set.Set UnifiedSortVariable
    -> Either (Error VerifyError) VerifySuccess
verifyPattern unifiedPattern maybeExpectedSort indexedModule sortVariables =
    internalVerifyPattern
        unifiedPattern
        maybeExpectedSort
        indexedModule
        sortVariables
        emptyDeclaredVariables

internalVerifyPattern
    :: UnifiedPattern
    -> Maybe UnifiedSort
    -> IndexedModule
    -> Set.Set UnifiedSortVariable
    -> DeclaredVariables
    -> Either (Error VerifyError) VerifySuccess
internalVerifyPattern
    (MetaPattern p@(StringLiteralPattern _))
    maybeExpectedSort
    _ _ _
  =
    withContext (patternNameForContext p) (do
        sort <- verifyStringPattern
        case maybeExpectedSort of
            Just expectedSort ->
                verifySameSort
                    expectedSort
                    (MetaSort sort)
            Nothing ->
                verifySuccess
    )
internalVerifyPattern
    (MetaPattern p)
    maybeExpectedSort
    indexedModule
    sortVariables
    declaredVariables
  =
    withContext (patternNameForContext p) (do
        sort <-
            verifyParametrizedPattern
                p
                indexedModule
                (metaVerifyHelpers indexedModule declaredVariables)
                sortVariables
                declaredVariables
        case maybeExpectedSort of
            Just expectedSort ->
                verifySameSort
                    expectedSort
                    (MetaSort sort)
            Nothing ->
                verifySuccess
    )
internalVerifyPattern
    (ObjectPattern p)
    maybeExpectedSort
    indexedModule
    sortVariables
    declaredVariables
  =
    withContext (patternNameForContext p) (do
        maybeSort <-
            verifyObjectPattern
                p indexedModule verifyHelpers sortVariables declaredVariables
        sort <-
            case maybeSort of
                Just s -> return s
                Nothing ->
                    verifyParametrizedPattern
                        p
                        indexedModule
                        verifyHelpers
                        sortVariables
                        declaredVariables
        case maybeExpectedSort of
            Just expectedSort ->
                verifySameSort
                    expectedSort
                    (ObjectSort sort)
            Nothing ->
                verifySuccess
    )
  where
    verifyHelpers = objectVerifyHelpers indexedModule declaredVariables

verifyParametrizedPattern
    :: IsMeta a
    => Pattern a
    -> IndexedModule
    -> VerifyHelpers a
    -> Set.Set UnifiedSortVariable
    -> DeclaredVariables
    -> Either (Error VerifyError) (Sort a)
verifyParametrizedPattern (AndPattern p)         = verifyMLPattern p
verifyParametrizedPattern (ApplicationPattern p) = verifyApplication p
verifyParametrizedPattern (BottomPattern p)      = verifyMLPattern p
verifyParametrizedPattern (CeilPattern p)        = verifyMLPattern p
verifyParametrizedPattern (EqualsPattern p)      = verifyMLPattern p
verifyParametrizedPattern (ExistsPattern p)      = verifyBinder p
verifyParametrizedPattern (FloorPattern p)       = verifyMLPattern p
verifyParametrizedPattern (ForallPattern p)      = verifyBinder p
verifyParametrizedPattern (IffPattern p)         = verifyMLPattern p
verifyParametrizedPattern (ImpliesPattern p)     = verifyMLPattern p
verifyParametrizedPattern (InPattern p)          = verifyMLPattern p
verifyParametrizedPattern (NotPattern p)         = verifyMLPattern p
verifyParametrizedPattern (OrPattern p)          = verifyMLPattern p
verifyParametrizedPattern (TopPattern p)         = verifyMLPattern p
verifyParametrizedPattern (VariablePattern p)    = verifyVariableUsage p

verifyObjectPattern
    :: Pattern Object
    -> IndexedModule
    -> VerifyHelpers Object
    -> Set.Set UnifiedSortVariable
    -> DeclaredVariables
    -> Either (Error VerifyError) (Maybe (Sort Object))
verifyObjectPattern (NextPattern p)     = maybeVerifyMLPattern p
verifyObjectPattern (RewritesPattern p) = maybeVerifyMLPattern p
verifyObjectPattern _                   = rightNothing
  where
    rightNothing _ _ _ _ = Right Nothing

maybeVerifyMLPattern
    :: (MLPatternClass p, IsMeta a)
    => p a
    -> IndexedModule
    -> VerifyHelpers a
    -> Set.Set UnifiedSortVariable
    -> DeclaredVariables
    -> Either (Error VerifyError) (Maybe (Sort a))
maybeVerifyMLPattern
    mlPattern
    indexedModule
    verifyHelpers
    declaredSortVariables
    declaredVariables
  =
    Just <$>
        verifyMLPattern
            mlPattern
            indexedModule
            verifyHelpers
            declaredSortVariables
            declaredVariables

verifyMLPattern
    :: (MLPatternClass p, IsMeta a)
    => p a
    -> IndexedModule
    -> VerifyHelpers a
    -> Set.Set UnifiedSortVariable
    -> DeclaredVariables
    -> Either (Error VerifyError) (Sort a)
verifyMLPattern
    mlPattern
    indexedModule
    verifyHelpers
    declaredSortVariables
    declaredVariables
  = do
    mapM_
        (verifySortUsage
            (verifyHelpersFindSort verifyHelpers)
            declaredSortVariables
        )
        (getPatternSorts mlPattern)
    verifyPatternsWithSorts
        operandSorts
        (getPatternPatterns mlPattern)
        indexedModule
        declaredSortVariables
        declaredVariables
    return returnSort
  where
    returnSort = getMLPatternResultSort mlPattern
    operandSorts = getMLPatternOperandSorts mlPattern


verifyPatternsWithSorts
    :: Typeable a
    => [Sort a]
    -> [UnifiedPattern]
    -> IndexedModule
    -> Set.Set UnifiedSortVariable
    -> DeclaredVariables
    -> Either (Error VerifyError) VerifySuccess
verifyPatternsWithSorts
    sorts
    operands
    indexedModule
    declaredSortVariables
    declaredVariables
  = do
    koreFailWhen (declaredOperandCount /= actualOperandCount)
        (  "Expected "
        ++ show declaredOperandCount
        ++ " operands, but got "
        ++ show actualOperandCount
        ++ "."
        )
    zipWithM_
        (\sort operand ->
            internalVerifyPattern
                operand
                (Just (asUnifiedSort sort))
                indexedModule
                declaredSortVariables
                declaredVariables
        )
        sorts
        operands
    verifySuccess
  where
    declaredOperandCount = length sorts
    actualOperandCount = length operands

verifyApplication
    :: IsMeta a
    => Application a
    -> IndexedModule
    -> VerifyHelpers a
    -> Set.Set UnifiedSortVariable
    -> DeclaredVariables
    -> Either (Error VerifyError) (Sort a)
verifyApplication
    application
    indexedModule
    verifyHelpers
    declaredSortVariables
    declaredVariables
  = do
    applicationSorts <-
        verifySymbolOrAlias
            (applicationSymbolOrAlias application)
            verifyHelpers
            declaredSortVariables
    verifyPatternsWithSorts
        (applicationSortsOperands applicationSorts)
        (applicationPatterns application)
        indexedModule
        declaredSortVariables
        declaredVariables
    return (applicationSortsReturn applicationSorts)

verifyBinder
    :: (MLBinderPatternClass p, IsMeta a)
    => p a
    -> IndexedModule
    -> VerifyHelpers a
    -> Set.Set UnifiedSortVariable
    -> DeclaredVariables
    -> Either (Error VerifyError) (Sort a)
verifyBinder
    binder
    indexedModule
    verifyHelpers
    declaredSortVariables
    declaredVariables
  = do
    verifyUnifiedVariableDeclaration
        quantifiedVariable indexedModule declaredSortVariables
    verifySortUsage
        (verifyHelpersFindSort verifyHelpers)
        declaredSortVariables
        binderSort
    internalVerifyPattern
        (getBinderPatternPattern binder)
        (Just (asUnifiedSort binderSort))
        indexedModule
        declaredSortVariables
        (addDeclaredVariable quantifiedVariable declaredVariables)
    return binderSort
  where
    quantifiedVariable = getBinderPatternVariable binder
    binderSort = getBinderPatternSort binder

verifyVariableUsage
    :: (Ord a, Typeable a)
    => Variable a
    -> IndexedModule
    -> VerifyHelpers a
    -> Set.Set UnifiedSortVariable
    -> DeclaredVariables
    -> Either (Error VerifyError) (Sort a)
verifyVariableUsage variable _ verifyHelpers _ _ = do
    declaredVariable <-
        findVariableDeclaration
            (variableName variable) verifyHelpers
    koreFailWhen
        (variableSort variable /= variableSort declaredVariable)
        "The declared sort is different."
    return (variableSort variable)

verifyStringPattern :: Either (Error VerifyError) (Sort Meta)
verifyStringPattern = Right stringMetaSort

verifyUnifiedVariableDeclaration
    :: UnifiedVariable
    -> IndexedModule
    -> Set.Set UnifiedSortVariable
    -> Either (Error VerifyError) VerifySuccess
verifyUnifiedVariableDeclaration
    (MetaVariable variable) indexedModule declaredSortVariables
  =
    verifySortUsage
        (resolveSort indexedModuleMetaSortDescriptions indexedModule)
        declaredSortVariables
        (variableSort variable)
verifyUnifiedVariableDeclaration
    (ObjectVariable variable) indexedModule declaredSortVariables
  = verifySortUsage
        (resolveSort indexedModuleObjectSortDescriptions indexedModule)
        declaredSortVariables
        (variableSort variable)

findVariableDeclaration
    :: (Ord a, Typeable a)
    => Id a
    -> VerifyHelpers a
    -> Either (Error VerifyError) (Variable a)
findVariableDeclaration variableId verifyHelpers =
    case findVariables variableId of
        Nothing ->
            koreFail ("Unquantified variable: '" ++ getId variableId ++ "'.")
        Just variable -> Right variable
  where
    findVariables = verifyHelpersFindDeclaredVariables verifyHelpers

verifySymbolOrAlias
    :: IsMeta a
    => SymbolOrAlias a
    -> VerifyHelpers a
    -> Set.Set UnifiedSortVariable
    -> Either (Error VerifyError) (ApplicationSorts a)
verifySymbolOrAlias symbolOrAlias verifyHelpers declaredSortVariables =
    case (maybeSentenceSymbol, maybeSentenceAlias) of
        (Just sentenceSymbol, Nothing) ->
            applicationSortsFromSymbolOrAliasSentence
                symbolOrAlias
                sentenceSymbol
                verifyHelpers
                declaredSortVariables
        (Nothing, Just sentenceAlias) ->
            applicationSortsFromSymbolOrAliasSentence
                symbolOrAlias
                sentenceAlias
                verifyHelpers
                declaredSortVariables
        (Nothing, Nothing) ->
            koreFail ("Symbol '" ++ getId applicationId ++ "' not defined.")
        -- The (Just, Just) match should be caught by the unique names check.
  where
    applicationId = symbolOrAliasConstructor symbolOrAlias
    symbolLookup = verifyHelpersLookupSymbolDeclaration verifyHelpers
    maybeSentenceSymbol = symbolLookup applicationId
    aliasLookup = verifyHelpersLookupAliasDeclaration verifyHelpers
    maybeSentenceAlias = aliasLookup applicationId

applicationSortsFromSymbolOrAliasSentence
    :: (IsMeta a, SentenceSymbolOrAlias sa)
    => SymbolOrAlias a
    -> sa a
    -> VerifyHelpers a
    -> Set.Set UnifiedSortVariable
    -> Either (Error VerifyError) (ApplicationSorts a)
applicationSortsFromSymbolOrAliasSentence
    symbolOrAlias sentence verifyHelpers declaredSortVariables
  = do
    mapM_
        ( verifySortUsage
            (verifyHelpersFindSort verifyHelpers)
            declaredSortVariables
        )
        (symbolOrAliasParams symbolOrAlias)
    variableSortPairs <-
        pairVariablesToSorts
            paramVariables
            (symbolOrAliasParams symbolOrAlias)
    fullReturnSort <-
        substituteSortVariables
            (Map.fromList variableSortPairs)
            parametrizedReturnSort
    operandSorts <-
        mapM
            (substituteSortVariables (Map.fromList variableSortPairs))
            parametrizedArgumentSorts
    return ApplicationSorts
        { applicationSortsOperands = operandSorts
        , applicationSortsReturn = fullReturnSort
        }
  where
    paramVariables = getSentenceSymbolOrAliasSortParams sentence
    parametrizedArgumentSorts = getSentenceSymbolOrAliasArgumentSorts sentence
    parametrizedReturnSort = getSentenceSymbolOrAliasReturnSort sentence


substituteSortVariables
    :: Map.Map (SortVariable a) (Sort a)
    -> Sort a
    -> Either (Error VerifyError) (Sort a)
substituteSortVariables variableToSort (SortVariableSort variable) =
    case Map.lookup variable variableToSort of
        Just sort -> Right sort
        -- The Nothing case should be caught by the sort checker.
substituteSortVariables
    variableToSort
    (SortActualSort sort@SortActual { sortActualSorts = sortList })
  = do
    substituted <- mapM (substituteSortVariables variableToSort) sortList
    return (SortActualSort sort { sortActualSorts = substituted })

pairVariablesToSorts
    :: [SortVariable a]
    -> [Sort a]
    -> Either (Error VerifyError) [(SortVariable a, Sort a)]
pairVariablesToSorts variables sorts
    | variablesLength < sortsLength =
        Left (koreError "Application uses more sorts than the declaration.")
    | variablesLength > sortsLength =
        Left (koreError "Application uses less sorts than the declaration.")
    | otherwise = Right (zip variables sorts)
  where
    variablesLength = length variables
    sortsLength = length sorts

verifySameSort
    :: UnifiedSort
    -> UnifiedSort
    -> Either (Error VerifyError) VerifySuccess
verifySameSort (ObjectSort expectedSort) (ObjectSort actualSort) = do
    koreFailWhen
        (expectedSort /= actualSort)
        (   "Expecting sort '"
            ++ unparseToString expectedSort
            ++ "' but got '"
            ++ unparseToString actualSort
            ++ "'."
        )
    verifySuccess
verifySameSort (MetaSort expectedSort) (MetaSort actualSort) = do
    koreFailWhen
        (expectedSort /= actualSort)
        (   "Expecting sort '"
            ++ unparseToString expectedSort
            ++ "' but got '"
            ++ unparseToString actualSort
            ++ "'."
        )
    verifySuccess
verifySameSort (MetaSort expectedSort) (ObjectSort actualSort) =
    koreFail
        (   "Expecting meta sort '"
            ++ unparseToString expectedSort
            ++ "' but got object sort '"
            ++ unparseToString actualSort
            ++ "'."
        )
verifySameSort (ObjectSort expectedSort) (MetaSort actualSort) =
    koreFail
        (   "Expecting object sort '"
            ++ unparseToString expectedSort
            ++ "' but got meta sort '"
            ++ unparseToString actualSort
            ++ "'."
        )

patternNameForContext :: Pattern a -> String
patternNameForContext (AndPattern _) = "\\and"
patternNameForContext (ApplicationPattern application) =
    "symbol or alias '"
    ++ getId (symbolOrAliasConstructor (applicationSymbolOrAlias application))
    ++ "'"
patternNameForContext (BottomPattern _) = "\\bottom"
patternNameForContext (CeilPattern _) = "\\ceil"
patternNameForContext (EqualsPattern _) = "\\equals"
patternNameForContext (ExistsPattern exists) =
    "\\exists '"
    ++ unifiedVariableNameForContext (existsVariable exists)
    ++ "'"
patternNameForContext (FloorPattern _) = "\\floor"
patternNameForContext (ForallPattern forall) =
    "\\forall '"
    ++ unifiedVariableNameForContext (forallVariable forall)
    ++ "'"
patternNameForContext (IffPattern _) = "\\iff"
patternNameForContext (ImpliesPattern _) = "\\implies"
patternNameForContext (InPattern _) = "\\in"
patternNameForContext (NextPattern _) = "\\next"
patternNameForContext (NotPattern _) = "\\not"
patternNameForContext (OrPattern _) = "\\or"
patternNameForContext (RewritesPattern _) = "\\rewrites"
patternNameForContext (StringLiteralPattern _) = "<string>"
patternNameForContext (TopPattern _) = "\\top"
patternNameForContext (VariablePattern variable) =
    "variable '" ++ variableNameForContext variable ++ "'"

unifiedVariableNameForContext :: UnifiedVariable -> String
unifiedVariableNameForContext = applyOnUnifiedVariable variableNameForContext

variableNameForContext :: Variable a -> String
variableNameForContext variable = getId (variableName variable)
