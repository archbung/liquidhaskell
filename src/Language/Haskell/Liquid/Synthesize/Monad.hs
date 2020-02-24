{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}

module Language.Haskell.Liquid.Synthesize.Monad where


import           Language.Haskell.Liquid.Bare.Resolve as B
import           Language.Haskell.Liquid.Types hiding (SVar)
import           Language.Haskell.Liquid.Constraint.Types
import           Language.Haskell.Liquid.Constraint.Generate 
import           Language.Haskell.Liquid.Constraint.Env 
import qualified Language.Haskell.Liquid.Types.RefType as R
import           Language.Haskell.Liquid.GHC.Misc (showPpr)
import           Language.Haskell.Liquid.Synthesize.Termination
import           Language.Haskell.Liquid.Synthesize.GHC hiding (SSEnv)
import           Language.Haskell.Liquid.Synthesize.Misc hiding (notrace)
import           Language.Haskell.Liquid.Constraint.Fresh (trueTy)
import qualified Language.Fixpoint.Smt.Interface as SMT
import           Language.Fixpoint.Types hiding (SEnv, SVar, Error)
import qualified Language.Fixpoint.Types        as F 
import qualified Language.Fixpoint.Types.Config as F

import CoreSyn (CoreExpr)
import qualified CoreSyn as GHC
import Var 
import TyCon
import DataCon
import TysWiredIn
import qualified TyCoRep as GHC 
import           Text.PrettyPrint.HughesPJ ((<+>), text, char, Doc, vcat, ($+$))

import           Control.Monad.State.Lazy
import qualified Data.HashMap.Strict as M 
import           Data.Default 
import           Data.Graph (SCC(..))
import qualified Data.Text as T
import           Data.Maybe
import           Debug.Trace 
import           Language.Haskell.Liquid.GHC.TypeRep

import           Data.List 
import qualified Data.Map as Map 
import           Data.List.Extra
import           CoreUtils (exprType)
import qualified Data.HashSet as S
import           Data.Tuple.Extra 

maxMatchDepth :: Int 
maxMatchDepth = 5 

-------------------------------------------------------------------------------
-- | Synthesis Monad ----------------------------------------------------------
-------------------------------------------------------------------------------

-- The state keeps a unique index for generation of fresh variables 
-- and the environment of variables to types that is expanded on lambda terms
type SSEnv = M.HashMap Symbol (SpecType, Var)
type SSDecrTerm = [(Var, [Var])]

type ExprMemory = [(Type, CoreExpr, Int)]
type T = M.HashMap Type (CoreExpr, Int)
data SState 
  = SState { rEnv       :: !REnv 
           , ssEnv      :: !SSEnv -- Local Binders Generated during Synthesis 
           , ssIdx      :: !Int
           , ssDecrTerm :: !SSDecrTerm 
           , sContext   :: !SMT.Context
           , sCGI       :: !CGInfo
           , sCGEnv     :: !CGEnv
           , sFCfg      :: !F.Config
           , sDepth     :: !Int
           , sExprMem   :: !ExprMemory 
           , sAppDepth  :: !Int
           , sUniVars   :: ![Var]
           , sFix       :: !Var
           , sGoalTyVar :: !(Maybe [TyVar])
           , sUGoalTy   :: !(Maybe [Type])     -- ^ Types used for instantiation.
                                            --   Produced by @withUnify@.
           , sForalls   :: !([Var], [[Type]])  -- ^ [Var] are the parametric functions (except for the fixpoint)
                                              --    e.g. Constructors, top-level functions.
                                              -- ^ [[Type]]: all the types that have instantiated [Var] so far.
           , caseIdx    :: !Int              -- [ Temporary ] Index in list of scrutinees.
           }
type SM = StateT SState IO

-- TODO Write: What is @maxAppDepth@?
maxAppDepth :: Int 
maxAppDepth = 4

locally :: SM a -> SM a 
locally act = do 
  st <- get 
  r <- act 
  modify $ \s -> s{sCGEnv = sCGEnv st, sCGI = sCGI st, sExprMem = sExprMem st}
  return r 


evalSM :: SM a -> SMT.Context -> FilePath -> F.Config -> CGInfo -> CGEnv -> REnv -> SSEnv -> SState -> IO a 
evalSM act ctx tgt fcfg cgi cgenv renv env st = do 
  let st' = st {ssEnv = env}
  r <- evalStateT act st'
  SMT.cleanupContext ctx 
  return r 

initState :: SMT.Context -> F.Config -> CGInfo -> CGEnv -> REnv -> Var -> [Var] -> SSEnv -> IO SState 
initState ctx fcfg cgi cgenv renv xtop uniVars env = 
  return $ SState renv env 0 [] ctx cgi cgenv fcfg 0 exprMem0 0 uniVars xtop Nothing Nothing ([], []) 0
  where exprMem0 = initExprMem env

getSEnv :: SM SSEnv
getSEnv = ssEnv <$> get 

getSEMem :: SM ExprMemory
getSEMem = sExprMem <$> get

getSFix :: SM Var 
getSFix = sFix <$> get

getSUniVars :: SM [Var]
getSUniVars = sUniVars <$> get

type LEnv = M.HashMap Symbol SpecType -- | Local env.

getLocalEnv :: SM LEnv
getLocalEnv = (reLocal . rEnv) <$> get

getSDecrTerms :: SM SSDecrTerm 
getSDecrTerms = ssDecrTerm <$> get

addsEnv :: [(Var, SpecType)] -> SM () 
addsEnv xts = 
  mapM_ (\(x,t) -> modify (\s -> s {ssEnv = M.insert (symbol x) (t,x) (ssEnv s)})) xts  

addsEmem :: [(Var, SpecType)] -> SM () 
addsEmem xts = do 
  curAppDepth <- sAppDepth <$> get
  mapM_ (\(x,t) -> modify (\s -> s {sExprMem = (toType t, GHC.Var x, curAppDepth+1) : (sExprMem s)})) xts  
  

addEnv :: Var -> SpecType -> SM ()
addEnv x t = do 
  liftCG0 (\γ -> γ += ("arg", symbol x, t))
  modify (\s -> s {ssEnv = M.insert (symbol x) (t,x) (ssEnv s)}) 

addEmem :: Var -> SpecType -> SM ()
addEmem x t = do 
  let ht0 = toType t
  curAppDepth <- sAppDepth <$> get
  xtop <- getSFix 
  (ht1, _) <- instantiateTL
  let ht = if x == xtop then ht1 else ht0
  modify (\s -> s {sExprMem = (ht, GHC.Var x, curAppDepth) : (sExprMem s)})

---------------------------------------------------------------------------------------------
--                         Handle structural termination checking                          --
---------------------------------------------------------------------------------------------
addDecrTerm :: Var -> [Var] -> SM ()
addDecrTerm x vars = do
  decrTerms <- getSDecrTerms 
  case lookup x decrTerms of 
    Nothing    -> modify (\s -> s { ssDecrTerm = (x, vars) : (ssDecrTerm s) } )
    Just vars' -> do
      let ix = elemIndex (x, vars') decrTerms
      case ix of 
        Nothing  -> error $ "[addDecrTerm] It should have been there " ++ show x 
        Just ix' -> 
          let (left, right) = splitAt ix' decrTerms 
          in  modify (\s -> s { ssDecrTerm =  left ++ [(x, vars ++ vars')] ++ right } )

-- | Entry point.
structuralCheck :: [CoreExpr] -> SM [CoreExpr]
structuralCheck es 
  = do  decr <- ssDecrTerm <$> get
        fix <- sFix <$> get
        return (filter (notStructural decr fix) es)

structCheck :: Var -> CoreExpr -> (Maybe Var, [CoreExpr])
structCheck xtop var@(GHC.Var v)
  = if v == xtop 
      then (Just xtop, [])
      else (Nothing, [var])
structCheck xtop (GHC.App e1 (GHC.Type _))
  = structCheck xtop e1
structCheck xtop (GHC.App e1 e2)
  =  (mbVar, e2:es)
    where (mbVar, es) = structCheck xtop e1
structCheck xtop (GHC.Let _ e) 
  = structCheck xtop e
structCheck xtop e 
  = error (" StructCheck " ++ show e)

notStructural :: SSDecrTerm -> Var -> CoreExpr -> Bool
notStructural decr xtop e
  = case v of
      Nothing -> True
      Just v  -> foldr (\x b -> isDecreasing' x decr && b) True args
  where (v, args) = (structCheck xtop e)

isDecreasing' :: CoreExpr -> SSDecrTerm -> Bool
isDecreasing' (GHC.Var v) decr
  = not (v `elem` map fst decr)
isDecreasing' e decr
  = True
---------------------------------------------------------------------------------------------
--                               END OF STRUCTURAL CHECK                                   --
---------------------------------------------------------------------------------------------

liftCG0 :: (CGEnv -> CG CGEnv) -> SM () 
liftCG0 act = do 
  st <- get 
  let (cgenv, cgi) = runState (act (sCGEnv st)) (sCGI st) 
  modify (\s -> s {sCGI = cgi, sCGEnv = cgenv}) 


liftCG :: CG a -> SM a 
liftCG act = do 
  st <- get 
  let (x, cgi) = runState act (sCGI st) 
  modify (\s -> s {sCGI = cgi})
  return x 


freshVarType :: Type -> SM Var
freshVarType t = (\i -> mkVar (Just "x") i t) <$> incrSM


freshVar :: SpecType -> SM Var
freshVar = freshVarType . toType

withIncrDepth :: Monoid a => SM a -> SM a
withIncrDepth m = do 
    s <- get 
    -- let maxAppDepth = typedHoles $ getConfig $ sCGEnv s 
    let d = sDepth s
    if d + 1 > maxMatchDepth 
      then return mempty
      else do put s{sDepth = d + 1}
              r <- m
              modify $ \s -> s{sDepth = d}
              return r
        
  
incrSM :: SM Int 
incrSM = do s <- get 
            put s{ssIdx = ssIdx s + 1}
            return (ssIdx s)

incrCase :: [a] -> SM Int 
incrCase es 
  = do  s <- get 
        put s { caseIdx = (caseIdx s + 1) `mod` (length es)}
        return (caseIdx s)
  

symbolExpr :: Type -> F.Symbol -> SM CoreExpr 
symbolExpr τ x = incrSM >>= (\i -> return $ F.notracepp ("symExpr for " ++ F.showpp x) $  GHC.Var $ mkVar (Just $ F.symbolString x) i τ)


-------------------------------------------------------------------------------------------------------
----------------------------------------- Handle ExprMemory -------------------------------------------
-------------------------------------------------------------------------------------------------------

-- | Initializes @ExprMemory@ structure.
--    1. Transforms refinement types to conventional (Haskell) types.
--    2. All @Depth@s are initialized to 0.
initExprMem :: SSEnv -> ExprMemory
initExprMem sEnv = map (\(_, (t, v)) -> (toType t, GHC.Var v, 0)) (M.toList sEnv)


-------------- Init @ExprMemory@ with instantiated functions with the right type (sUGoalTy) -----------
insEMem0 :: SSEnv -> SM ExprMemory
insEMem0 senv = do
  xtop      <- getSFix
  (ttop, _) <- instantiateTL
  mbUTy     <- sUGoalTy <$> get 
  uniVs <- sUniVars <$> get

  let ts = fromMaybe [] mbUTy
  ts0 <- (snd . sForalls) <$> get
  fs0 <- (fst . sForalls) <$> get
  modify ( \s -> s { sForalls = (fs0, ts : ts0) } )

  let handleIt e = case e of  GHC.Var v -> if xtop == v 
                                              then (instantiate e (Just uniVs), ttop) 
                                              else change e
                              _         -> change e
      change e =  let { e' = instantiateTy e mbUTy; t' = exprType e' } 
                  in  (e', t')

  return $ map (\(t, e, i) -> let (e', t') = handleIt e
                              in  (t', e', i)) (initExprMem senv)

instantiateTy :: CoreExpr -> Maybe [Type] -> CoreExpr
instantiateTy e mbTy = 
  case mbTy of 
    Nothing  -> e
    Just tys -> case applyTy tys e of 
                  Nothing -> e
                  Just e0 -> e0

-- | Used for instantiation: Applies types to an expression.
--   > The result does not have @forall@.
--   Nothing as a result suggests that there are more types than foralls in the expression.
applyTy :: [Type] -> GHC.CoreExpr -> Maybe GHC.CoreExpr
applyTy []     e =  case exprType e of 
                      ForAllTy{} -> Nothing
                      _          -> Just e
applyTy (t:ts) e =  case exprType e of
                      ForAllTy{} -> applyTy ts (GHC.App e (GHC.Type t))
                      _          -> Nothing

-- | Instantiation based on current goal-type.
fixEMem :: SpecType -> SM ()
fixEMem t
  = do  (fs, ts) <- sForalls <$> get
        let uTys = unifyWith (toType t)
        needsFix <- case find (== uTys) ts of 
                      Nothing -> return True   -- not yet instantiated
                      Just _  -> return False  -- already instantiated

        when needsFix $
          do  modify (\s -> s { sForalls = (fs, uTys : ts)})
              let notForall e = case exprType e of {ForAllTy{} -> False; _ -> True}
                  es = map (\v -> instantiateTy (GHC.Var v) (Just uTys)) fs
                  fixEs = filter notForall es
              thisDepth <- sDepth <$> get
              let fixedEMem = map (\e -> (exprType e, e, thisDepth + 1)) fixEs
              modify (\s -> s {sExprMem = fixedEMem ++ sExprMem s})

------------------------------------------------------------------------------------------------
------------------------------ Special handle for the current fixpoint -------------------------
------------------------------------------------------------------------------------------------

-- | Instantiate the top-level variable.
instantiateTL :: SM (Type, GHC.CoreExpr)
instantiateTL = do
  uniVars <- getSUniVars 
  xtop <- getSFix
  let e = apply uniVars (GHC.Var xtop)
  return (exprType e, e)

-- | Applies type variables (1st argument) to an expression.
--   The expression is guaranteed to have the same level of 
--   parametricity (same number of @forall@) as the length of the 1st argument.
--   > The result has zero @forall@.
apply :: [Var] -> GHC.CoreExpr -> GHC.CoreExpr
apply []     e = 
  case exprType e of 
    ForAllTy {} -> error $ " [ instantiate (1) ] For e " ++ show e
    _           -> e
apply (v:vs) e 
  = case exprType e of 
      ForAllTy{} -> apply vs (GHC.App e (GHC.Type (TyVarTy v)))
      _          -> error $ " [ instantiate (2) ] For e " ++ show e ++ " vars = " ++ show (v:vs)

instantiate :: CoreExpr -> Maybe [Var] -> CoreExpr
instantiate e mbt = 
  case mbt of
    Nothing     -> e
    Just tyVars -> apply tyVars e

-----------------------------------------------------------------------------------------------------

withTypeEs :: String -> SpecType -> SM [CoreExpr] 
withTypeEs s t = do 
    em <- sExprMem <$> get 
    return (map snd3 (filter (\x -> fst3 x == toType t) em)) 

findCandidates :: Type ->         -- ^ Goal type: Find all candidate expressions of this type,
                                  --   or that produce this type (i.e. functions).
                  SM ExprMemory
findCandidates goalTy = do
  sEMem <- sExprMem <$> get
  return (filter ((goalType goalTy) . fst3) sEMem)

functionCands :: Type -> SM [(Type, GHC.CoreExpr, Int)]
functionCands goalTy = do 
  all <- findCandidates goalTy 
  return (filter (isFunction . fst3) all)


---------------------------------------------------------------------------------
--------------------------- Generate error expression ---------------------------
---------------------------------------------------------------------------------

varError :: SM Var
varError = do 
  info    <- ghcI . sCGI <$> get -- CGInfo
  let env  = B.makeEnv (gsConfig $ giSpec info) (giSrc info) mempty mempty 
  let name = giTargetMod $ giSrc info
  return $ B.lookupGhcVar env name "Var" (dummyLoc $ symbol "Language.Haskell.Liquid.Synthesize.Error.err")
