module ProjectM36.AtomType where
import ProjectM36.Base
import qualified ProjectM36.TypeConstructorDef as TCD
import qualified ProjectM36.TypeConstructor as TC
import qualified ProjectM36.DataConstructorDef as DCD
import ProjectM36.MiscUtils
import ProjectM36.Error
import ProjectM36.DataTypes.Primitive
import qualified ProjectM36.Attribute as A
import qualified Data.Vector as V
import qualified Data.Set as S
import qualified Data.List as L
import Data.Maybe (isJust)
import Data.Either (rights, lefts)
import Control.Monad.Writer
import qualified Data.Map as M
import qualified Data.Text as T

findDataConstructor :: DataConstructorName -> TypeConstructorMapping -> Maybe (TypeConstructorDef, DataConstructorDef)
findDataConstructor dName tConsList = foldr tConsFolder Nothing tConsList
  where
    tConsFolder (tCons, dConsList) accum = if isJust accum then
                                accum
                              else
                                case findDCons dConsList of
                                  Just dCons -> Just (tCons, dCons)
                                  Nothing -> Nothing
    findDCons dConsList = case filter (\dCons -> DCD.name dCons == dName) dConsList of
      [] -> Nothing
      [dCons] -> Just dCons
      _ -> error "More than one data constructor with the same name found"
  
-- | Scan the atom types and return the resultant ConstructedAtomType or error.
-- Used in typeFromAtomExpr to validate argument types.
atomTypeForDataConstructorName :: DataConstructorName -> [AtomType] -> TypeConstructorMapping -> Either RelationalError AtomType
-- search for the data constructor and resolve the types' names
atomTypeForDataConstructorName dConsName atomTypesIn tConsList = do
  case findDataConstructor dConsName tConsList of
    Nothing -> Left (NoSuchDataConstructorError dConsName)
    Just (tCons, dCons) -> do
      typeVars <- resolveDataConstructorTypeVars dCons atomTypesIn tConsList
      pure (ConstructedAtomType (TCD.name tCons) typeVars)
        
atomTypeForDataConstructorDefArg :: DataConstructorDefArg -> AtomType -> TypeConstructorMapping -> Either RelationalError AtomType
atomTypeForDataConstructorDefArg (DataConstructorDefTypeConstructorArg tCons) aType tConss = 
  case isValidAtomTypeForTypeConstructor aType tCons tConss of
    Just err -> Left err
    Nothing -> Right aType

atomTypeForDataConstructorDefArg (DataConstructorDefTypeVarNameArg _) aType _ = Right aType --any type is OK
        
--reconcile the atom-in types with the type constructors
isValidAtomTypeForTypeConstructor :: AtomType -> TypeConstructor -> TypeConstructorMapping -> Maybe RelationalError
isValidAtomTypeForTypeConstructor aType (PrimitiveTypeConstructor _ expectedAType) _ = if expectedAType /= aType then Just (AtomTypeMismatchError expectedAType aType) else Nothing

--lookup constructor name and check if the incoming atom types are valid
isValidAtomTypeForTypeConstructor (ConstructedAtomType tConsName _) (ADTypeConstructor expectedTConsName _) _ =  if tConsName /= expectedTConsName then Just (TypeConstructorNameMismatch expectedTConsName tConsName) else Nothing

isValidAtomTypeForTypeConstructor aType tCons _ = Just (AtomTypeTypeConstructorReconciliationError aType (TC.name tCons))

-- | Used to determine if the atom arguments can be used with the data constructor.  
-- | This is the entry point for type-checking from RelationalExpression.hs.
atomTypeForDataConstructor :: TypeConstructorMapping -> DataConstructorName -> [AtomType] -> Either RelationalError AtomType
atomTypeForDataConstructor tConss dConsName atomArgTypes = do
  --lookup the data constructor
  case findDataConstructor dConsName tConss of
    Nothing -> Left (NoSuchDataConstructorError dConsName)
    Just (tCons, dCons) -> do
      --validate that the type constructor arguments are fulfilled in the data constructor
      typeVars <- resolveDataConstructorTypeVars dCons atomArgTypes tConss
      pure (ConstructedAtomType (TCD.name tCons) typeVars)
      
-- | Walks the data and type constructors to extract the type variable map.
resolveDataConstructorTypeVars :: DataConstructorDef -> [AtomType] -> TypeConstructorMapping -> Either RelationalError TypeVarMap
resolveDataConstructorTypeVars dCons aTypeArgs tConss = do
  maps <- mapM (\(dCons',aTypeArg) -> resolveDataConstructorArgTypeVars dCons' aTypeArg tConss) (zip (DCD.fields dCons) aTypeArgs)
  --if any two maps have the same key and different values, this indicates a type arg mismatch
  let typeVarMapFolder valMap acc = case acc of
        Left err -> Left err
        Right accMap -> if accMap `M.isSubmapOf` valMap then
                          Right (M.union accMap valMap)
                        else
                          Left (DataConstructorTypeVarsMismatch (DCD.name dCons) accMap valMap)
  case foldr typeVarMapFolder (Right M.empty) maps of
    Left err -> Left err
    Right typeVarMaps -> pure typeVarMaps
  --if the data constructor cannot complete a type constructor variables (ex. "Nothing" could be Maybe Int or Maybe Text, etc.), then fill that space with TypeVar which is resolved when the relation is constructed- the relation must contain all resolved atom types.


-- | Attempt to match the data constructor argument to a type constructor type variable.
resolveDataConstructorArgTypeVars :: DataConstructorDefArg -> AtomType -> TypeConstructorMapping -> Either RelationalError TypeVarMap
resolveDataConstructorArgTypeVars (DataConstructorDefTypeConstructorArg tCons) aType tConss = resolveTypeConstructorTypeVars tCons aType tConss
  
resolveDataConstructorArgTypeVars (DataConstructorDefTypeVarNameArg pVarName) aType _ = Right (M.singleton pVarName aType)

resolveTypeConstructorTypeVars :: TypeConstructor -> AtomType -> TypeConstructorMapping -> Either RelationalError TypeVarMap
resolveTypeConstructorTypeVars (PrimitiveTypeConstructor _ pType) aType _ = 
  if aType /= pType then
    Left (AtomTypeMismatchError pType aType)
  else
    Right M.empty

resolveTypeConstructorTypeVars (ADTypeConstructor tConsName _) (ConstructedAtomType tConsName' pVarMap') tConss = 
  if tConsName /= tConsName' then
    Left (TypeConstructorNameMismatch tConsName tConsName')
  else
    case findTypeConstructor tConsName tConss of
      Nothing -> Left (NoSuchTypeConstructorName tConsName)
      Just (tConsDef, _) -> let expectedPVarNames = S.fromList (TCD.typeVars tConsDef) in
        if M.keysSet pVarMap' `S.isSubsetOf` expectedPVarNames then
          Right pVarMap' 
        else
          Left (TypeConstructorTypeVarsMismatch expectedPVarNames (M.keysSet pVarMap'))
resolveTypeConstructorTypeVars (TypeVariable tvName) typ _ = Right (M.singleton tvName typ)          
resolveTypeConstructorTypeVars x y _ = error $ "Unhandled type vars:"  ++ show x ++ show y                             
    
-- check that type vars on the right also appear on the left
-- check that the data constructor names are unique      
validateTypeConstructorDef :: TypeConstructorDef -> [DataConstructorDef] -> [RelationalError]
validateTypeConstructorDef tConsDef dConsList = execWriter $ do
  let duplicateDConsNames = dupes (L.sort (map DCD.name dConsList))
  mapM_ tell [map DataConstructorNameInUseError duplicateDConsNames]
  let leftSideVars = S.fromList (TCD.typeVars tConsDef)
      rightSideVars = S.unions (map DCD.typeVars dConsList)
      varsDiff = S.difference leftSideVars rightSideVars
  mapM_ tell [map DataConstructorUsesUndeclaredTypeVariable (S.toList varsDiff)]
  pure ()
    

-- | Create an atom type iff all type variables are provided.
-- Either Int Text -> ConstructedAtomType "Either" {Int , Text}
atomTypeForTypeConstructor :: TypeConstructor -> TypeConstructorMapping -> Either RelationalError AtomType
atomTypeForTypeConstructor (PrimitiveTypeConstructor _ aType) _ = Right aType
atomTypeForTypeConstructor (TypeVariable tvname) _ = Right (TypeVariableType tvname)
atomTypeForTypeConstructor tCons tConss = case findTypeConstructor (TC.name tCons) tConss of
  Nothing -> Left (NoSuchTypeConstructorError (TC.name tCons))
  Just (tConsDef, _) -> do
      tConsArgTypes <- mapM ((flip atomTypeForTypeConstructor) tConss) (TC.arguments tCons)    
      let pVarNames = TCD.typeVars tConsDef
          tConsArgs = M.fromList (zip pVarNames tConsArgTypes)
      Right (ConstructedAtomType (TC.name tCons) tConsArgs)      

findTypeConstructor :: TypeConstructorName -> TypeConstructorMapping -> Maybe (TypeConstructorDef, [DataConstructorDef])
findTypeConstructor name tConsList = foldr tConsFolder Nothing tConsList
  where
    tConsFolder (tCons, dConsList) accum = if TCD.name tCons == name then
                                     Just (tCons, dConsList)
                                   else
                                     accum
                                    
resolveAtomType :: AtomType -> AtomType -> Either RelationalError AtomType  
resolveAtomType (ConstructedAtomType tConsName resolvedTypeVarMap) (ConstructedAtomType _ unresolvedTypeVarMap) = do  
  tVarMap <- resolveAtomTypesInTypeVarMap resolvedTypeVarMap unresolvedTypeVarMap
  pure (ConstructedAtomType tConsName tVarMap)
resolveAtomType typeFromRelation unresolvedType = if typeFromRelation == unresolvedType then
                                                    Right typeFromRelation
                                                  else
                                                    Left (AtomTypeMismatchError typeFromRelation unresolvedType)
                                                    
-- this could be optimized to reduce new tuple creation- if anyatomtype does not appear, just return the original typevarmap
resolveAtomTypesInTypeVarMap :: TypeVarMap -> TypeVarMap -> Either RelationalError TypeVarMap
resolveAtomTypesInTypeVarMap resolvedTypeMap unresolvedTypeMap = do
  {-
  let resKeySet = traceShowId $ M.keysSet resolvedTypeMap
      unresKeySet = traceShowId $ M.keysSet unresolvedTypeMap
  when (resKeySet /= unresKeySet) (Left $ TypeConstructorTypeVarsMismatch resKeySet unresKeySet)
  

  let lookupOrDef key tMap = case M.lookup key tMap of
        Nothing -> Left (TypeConstructorTypeVarMissing key)
        Just val -> Right val
  -}
  let resolveTypePair resKey resType = do
        -- if the key is missing in the unresolved type map, then fill it in with the value from the resolved map
        case M.lookup resKey unresolvedTypeMap of
          Just unresType -> case unresType of 
            --do we need to recurse for RelationAtomType?
            subType@(ConstructedAtomType _ _) -> do
              resSubType <- resolveAtomType resType subType
              pure (resKey, resSubType)
            otherType -> pure (resKey, otherType)
          Nothing -> do
            pure (resKey, resType) --swipe the missing type var from the expected map
  tVarList <- mapM (uncurry resolveTypePair) (M.toList resolvedTypeMap)
  pure (M.fromList tVarList)
  
-- | See notes at `resolveTypesInTuple`. The typeFromRelation must not include any wildcards.
resolveTypeInAtom :: AtomType -> Atom -> Either RelationalError Atom
resolveTypeInAtom typeFromRelation atomIn@(ConstructedAtom dConsName _ args) = do
  newType <- resolveAtomType typeFromRelation (atomTypeForAtom atomIn)
  pure (ConstructedAtom dConsName newType args)
resolveTypeInAtom _ atom = Right atom
  
-- | When creating a tuple, the data constructor may not complete the type constructor arguments, so the wildcard "TypeVar x" fills in the type constructor's argument. The tuple type must be resolved before it can be part of a relation, however.
-- Example: "Nothing" does not specify the the argument in "Maybe a", so allow delayed resolution in the tuple before it is added to the relation. Note that this resolution could cause a type error. Hardly a Hindley-Milner system.
resolveTypesInTuple :: Attributes -> RelationTuple -> Either RelationalError RelationTuple
resolveTypesInTuple resolvedAttrs (RelationTuple _ tupAtoms) = do
  newAtoms <- mapM (\(atom, resolvedType) -> resolveTypeInAtom resolvedType atom) (zip (V.toList tupAtoms) $ (map A.atomType (V.toList resolvedAttrs)))
  Right (RelationTuple resolvedAttrs (V.fromList newAtoms))
                           
-- | Validate that the type is provided with complete type variables for type constructors.
validateAtomType :: AtomType -> TypeConstructorMapping -> Either RelationalError ()
validateAtomType typ@(ConstructedAtomType tConsName tVarMap) tConss = do
  case findTypeConstructor tConsName tConss of 
    Nothing -> Left (TypeConstructorAtomTypeMismatch tConsName typ)
    Just (tConsDef, _) -> case tConsDef of
      ADTypeConstructorDef _ tVarNames -> let expectedTyVarNames = S.fromList tVarNames
                                              actualTyVarNames = M.keysSet tVarMap
                                              diff = S.difference expectedTyVarNames actualTyVarNames in
                                          if not (S.null diff) then
                                            Left $ TypeConstructorTypeVarsMismatch expectedTyVarNames actualTyVarNames
                                          else
                                            Right ()
      _ -> Right ()                                            
validateAtomType _ _ = Right ()

validateTuple :: RelationTuple -> TypeConstructorMapping -> Either RelationalError ()
validateTuple (RelationTuple _ atoms) tConss = mapM_ (\a -> validateAtomType (atomTypeForAtom a) tConss) atoms

-- | Determine if two types are equal or compatible (including special handling for TypeVar x).
atomTypeVerify :: AtomType -> AtomType -> Either RelationalError AtomType
atomTypeVerify (TypeVariableType _) x = Right x
atomTypeVerify x (TypeVariableType _) = Right x
atomTypeVerify x@(ConstructedAtomType tConsNameA tVarMapA) (ConstructedAtomType tConsNameB tVarMapB) = 
  if tConsNameA /= tConsNameB then
    Left (TypeConstructorNameMismatch tConsNameA tConsNameB)
  else if not (typeVarMapsVerify tVarMapA tVarMapB) then
         Left (TypeConstructorTypeVarsTypesMismatch tConsNameA tVarMapA tVarMapB)
       else
         Right x
atomTypeVerify x@(RelationAtomType attrs1) y@(RelationAtomType attrs2) = do
  _ <- mapM (\(attr1,attr2) -> let name1 = A.attributeName attr1
                                   name2 = A.attributeName attr2 in
                               if notElem "_" [name1, name2] && name1 /= name2 then 
                                 Left $ AtomTypeMismatchError x y
                               else
                                 atomTypeVerify (A.atomType attr1) (A.atomType attr2)) $ V.toList (V.zip attrs1 attrs2)
  return x
atomTypeVerify x y = if x == y then
                       Right x
                     else
                       Left $ AtomTypeMismatchError x y

-- | Determine if two typeVar
typeVarMapsVerify :: TypeVarMap -> TypeVarMap -> Bool
typeVarMapsVerify a b = M.keysSet a == M.keysSet b && (length . rights) (map (\((_,v1),(_,v2)) -> atomTypeVerify v1 v2) (zip (M.toAscList a) (M.toAscList b))) == M.size a

prettyAtomType :: AtomType -> T.Text
prettyAtomType (RelationAtomType attrs) = "relation {" `T.append` T.intercalate "," (map prettyAttribute (V.toList attrs)) `T.append` "}"
prettyAtomType (ConstructedAtomType tConsName typeVarMap) = tConsName `T.append` T.concat (map showTypeVars (M.toList typeVarMap))
  where
    showTypeVars (tyVarName, aType) = " (" `T.append` tyVarName `T.append` "::" `T.append` prettyAtomType aType `T.append` ")"
-- it would be nice to have the original ordering, but we don't have access to the type constructor here- maybe the typevarmap should be also positional (ordered map?)
prettyAtomType (TypeVariableType x) = "?TypeVariableType " <> x <> "?"
prettyAtomType aType = T.take (T.length fullName - T.length "AtomType") fullName
  where fullName = (T.pack . show) aType

prettyAttribute :: Attribute -> T.Text
prettyAttribute attr = A.attributeName attr `T.append` "::" `T.append` prettyAtomType (A.atomType attr)

resolveTypeVariables :: [AtomType] -> [AtomType] -> Either RelationalError TypeVarMap  
resolveTypeVariables expectedArgTypes actualArgTypes = do
  let tvmaps = map (uncurry resolveTypeVariable) (zip expectedArgTypes actualArgTypes)
  --if there are any new keys which don't have equal values then we have a conflict!
  foldM (\acc tvmap -> do
            let inter = M.intersectionWithKey (\tvName vala valb -> 
                                                if vala /= valb then
                                                  Left (AtomFunctionTypeVariableMismatch tvName vala valb)
                                                else
                                                  Right vala) acc tvmap
                errs = lefts (M.elems inter)
            case errs of
              [] -> pure (M.unions tvmaps)
              errs' -> Left (someErrors errs')) M.empty tvmaps
  
resolveTypeVariable :: AtomType -> AtomType -> TypeVarMap
resolveTypeVariable (TypeVariableType tv) typ = M.singleton tv typ
resolveTypeVariable (ConstructedAtomType _ _) (ConstructedAtomType _ actualTvMap) = actualTvMap
resolveTypeVariable _ _ = M.empty

resolveFunctionReturnValue :: AtomFunctionName -> TypeVarMap -> AtomType -> Either RelationalError AtomType
resolveFunctionReturnValue funcName tvMap (ConstructedAtomType tCons retMap) = do
  let diff = M.difference retMap tvMap
  if M.null diff then
    pure (ConstructedAtomType tCons (M.intersection tvMap retMap))
    else
    Left (AtomFunctionTypeVariableResolutionError funcName (fst (head (M.toList diff))))
resolveFunctionReturnValue funcName tvMap (TypeVariableType tvName) = case M.lookup tvName tvMap of
  Nothing -> Left (AtomFunctionTypeVariableResolutionError funcName tvName)
  Just typ -> pure typ
resolveFunctionReturnValue _ _ typ = pure typ