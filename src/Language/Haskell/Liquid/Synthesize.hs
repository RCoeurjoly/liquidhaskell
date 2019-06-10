{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances    #-}

module Language.Haskell.Liquid.Synthesize (
    synthesize
  ) where

import           Language.Haskell.Liquid.Types hiding (SVar)
import           Language.Haskell.Liquid.Constraint.Types
import           Language.Haskell.Liquid.Constraint.Generate 
import           Language.Haskell.Liquid.Constraint.Env 
import qualified Language.Haskell.Liquid.Types.RefType as R
import           Language.Haskell.Liquid.GHC.Misc (showPpr)
import           Language.Haskell.Liquid.Synthesize.GHC
import           Language.Haskell.Liquid.Synthesize.Check
import qualified Language.Fixpoint.Smt.Interface as SMT
import           Language.Fixpoint.Types hiding (SEnv, SVar, Error)
import qualified Language.Fixpoint.Types        as F 
import qualified Language.Fixpoint.Types.Config as F


import CoreSyn (CoreExpr)
import qualified CoreSyn as GHC
import Var 
import TyCon
import DataCon
import qualified TyCoRep as GHC 
import           Text.PrettyPrint.HughesPJ ((<+>), text, char, Doc, vcat, ($+$))

import           Control.Monad.State.Lazy
import qualified Data.HashMap.Strict as M 
import           Data.Default 
import qualified Data.Text as T
import           Data.Maybe
import           Debug.Trace 



synthesize :: FilePath -> F.Config -> CGInfo -> IO [Error]
synthesize tgt fcfg cginfo = mapM go $ M.toList (holesMap cginfo)
  where 
    go (x, HoleInfo t loc env (cgi,cge)) = do 
      fills <- synthesize' tgt fcfg cgi cge mempty x t 
      return $ ErrHole loc (if length fills > 0 then text "\n Hole Fills: " <+> pprintMany fills else mempty)
                       mempty (symbol x) t 

synthesize' :: FilePath -> F.Config -> CGInfo -> CGEnv -> SSEnv -> Var -> SpecType -> IO [CoreExpr]
synthesize' tgt fcfg cgi ctx senv x tx = (:[]) <$> evalSM (go tx) tgt fcfg cgi ctx senv
  where 

    go :: SpecType -> SM CoreExpr

    -- Type Abstraction 
    go (RAllT a t)       = GHC.Lam (tyVarVar a) <$> go t
    go (RFun x tx t _)   = 
      do  y <- freshVar tx
          addEnv y tx 
          GHC.Lam y <$> go (t `subst1` (x, EVar $ symbol y))
          
    -- Special Treatment for synthesis of integers          
    go t@(RApp c _ts _ r)  
      | R.isNumeric (tyConEmbed cgi) c = 
          do  let RR s (Reft(x,rr)) = rTypeSortedReft (tyConEmbed cgi) t 
              ctx <- sContext <$> get 
              liftIO $ SMT.smtPush ctx
              liftIO $ SMT.smtDecl ctx x s
              liftIO $ SMT.smtCheckSat ctx rr 
              -- Get model and parse the value of x
              SMT.Model modelBinds <- liftIO $ SMT.smtGetModel ctx
              
              let xNotFound = error $ "Symbol " ++ show x ++ "not found."
                  smtVal = T.unpack $ fromMaybe xNotFound $ lookup x modelBinds

              liftIO (SMT.smtPop ctx)
              return $ notracepp ("numeric with " ++ show r) (GHC.Var $ mkVar (Just smtVal) def def)

    go t = do addEnv x tx -- NV TODO: edit the type of x to ensure termination 
              synthesizeBasic t 
    
synthesizeBasic :: SpecType -> SM CoreExpr 
synthesizeBasic t = do es <- generateETerms t
                       ok <- findM (hasType t) es 
                       case ok of 
                        Just e  -> return e 
                        Nothing -> getSEnv >>= (`synthesizeMatch` t)  



-- Panagiotis TODO: this should generates all e-terms, but now it only generates variables in the environment                    
generateETerms :: SpecType -> SM [CoreExpr] 
generateETerms t = do 
  lenv <- M.toList . ssEnv <$> get 
  return [ GHC.Var v | (x, (tx, v)) <- lenv , τ == toType tx ] 
  where τ = toType t 

  
-- Panagiotis TODO: here I only explore the first one                     
synthesizeMatch :: SSEnv -> SpecType -> SM CoreExpr 
synthesizeMatch γ t 
  | (e:_) <- es 
  = do d <- incrDepth
       if d <= maxDepth then matchOn t e else return def 
  | otherwise 
  = return def 
  where es = [(v,t,rtc_tc c) | (x, (t@(RApp c _ _ _), v)) <- M.toList γ] 

maxDepth :: Int 
maxDepth = 1 

matchOn :: SpecType -> (Var, SpecType, TyCon) -> SM CoreExpr 
matchOn t (v, tx, c) = GHC.Case (GHC.Var v) v (toType tx) <$> mapM (makeAlt v t) (tyConDataCons c)

makeAlt :: Var -> SpecType -> DataCon -> SM GHC.CoreAlt 
makeAlt x t c = do -- (AltCon, [b], Expr b)
  xs <- mapM freshVar ts 
  addsEnv $ zip xs ts 
  liftCG (\γ -> caseEnv γ x mempty (GHC.DataAlt c) xs Nothing)
  e <- synthesizeBasic t
  return (GHC.DataAlt c, xs, e)
  where ts = [] 

hasType :: SpecType -> CoreExpr -> SM Bool
hasType t e = do 
  x  <- freshVar t 
  st <- get 
  r <- liftIO $ check (sCGI st) (sCGEnv st) (sFCfg st) x e t 
  liftIO $ putStrLn ("Checked:  Expr = " ++ showPpr e ++ " of type " ++ show t ++ "\n Res = " ++ show r)
  return r 

findM :: Monad m => (a -> m Bool) -> [a] -> m (Maybe a)
findM _ []     = return Nothing
findM p (x:xs) = do b <- p x ; if b then return (Just x) else findM p xs 

{- 
    {- OLD STUFF -}
    -- Type Variable
    go (RVar α _)        = (`synthesizeRVar` α) <$> getSEnv
    -- Function 

    -- Data Type, e.g., c = Int and ts = [] or c = List and ts = [a] 
              -- return def
    go (RApp _c _ts _ _) 
      = return def 
    -- Type Application, e.g, m a 
    go RAppTy{} = return def 


    -- Fancy Liquid Types to be ignored for now since they do not map to haskell types
    go (RImpF _ _ t _) = go t 
    go (RAllP _ t)     = go t 
    go (RAllS _ t)     = go t 
    go (RAllE _ _ t)   = go t 
    go (REx _ _ t)     = go t 
    go (RRTy _ _ _ t)  = go t 
    go (RExprArg _)    = return def 
    go (RHole _)       = return def 
-}
------------------------------------------------------------------------------
-- Handle dependent arguments
------------------------------------------------------------------------------
-- * Arithmetic refinement expressions: 
--    > All constants right, all variables left
------------------------------------------------------------------------------
-- depsSort :: Expr -> Expr 
-- depsSort e = 
--   case e of 
--     PAnd exprs -> PAnd (map depsSort exprs)
--       -- error "PAnd not implemented yet"
--     PAtom brel e1 e2 -> PAtom brel (depsSort e1)
--       -- error ("e1 = " ++ show e1)
--       -- error "PAtom not implemented yet"
--     ESym _symConst -> error "ESym not implemented yet" 
--     constant@(ECon _c) -> constant 
--     EVar _symbol -> error "EVar not implemented yet"
--     EApp _expr1 _expr2 -> error "EVar not implemented yet"
--     ENeg _expr -> error "ENeg not implemented yet"
--     EBin _bop _expr1 _expr2 -> error "EBin not implemented yet"
--     EIte _expr1 _expr2 _expr3 -> error "EIte not implemented yet"
--     ECst _expr _sort -> error "ECst not implemented yet"
--     ELam _targ _expr -> error "ELam not implemented yet"
--     ETApp _expr _sort -> error "ETApp not implemented yet"
--     ETAbs _expr _symbol -> error "ETAbs not implemented yet"
--     POr _exprLst -> error "POr not implemented yet" 
--     PNot _expr -> error "PNot not implemented yet"
--     PImp _expr1 _expr2 -> error "PImp not implemented yet"
--     PIff _expr1 _expr2 -> error "PIff not implemented yet"
--     PKVar _kvar _subst -> error "PKVar not implemented yet"
--     PAll _ _expr -> error "PAll not implemented yet"
--     PExist _ _expr -> error "PExist not implemented yet" 
--     PGrad _kvar _subst _gradInfo _expr -> error "PGrad not implemented yet"
--     ECoerc _sort1 _sort2 _expr -> error "ECoerc not implemented yet"


symbolExpr :: GHC.Type -> Symbol -> SM CoreExpr 
symbolExpr τ x = incrSM >>= (\i -> return $ notracepp ("symExpr for " ++ showpp x) $  GHC.Var $ mkVar (Just $ symbolString x) i τ)

-------------------------------------------------------------------------------
-- | Synthesis Monad ----------------------------------------------------------
-------------------------------------------------------------------------------

-- The state keeps a unique index for generation of fresh variables 
-- and the environment of variables to types that is expanded on lambda terms
type SSEnv = M.HashMap Symbol (SpecType, Var)

data SState 
  = SState { ssEnv    :: SSEnv -- Local Binders Generated during Synthesis 
           , ssIdx    :: Int
           , sContext :: SMT.Context
           , sCGI     :: CGInfo
           , sCGEnv   :: CGEnv
           , sFCfg    :: F.Config
           , sDepth   :: Int 
           }
type SM = StateT SState IO

evalSM :: SM a -> FilePath -> F.Config -> CGInfo -> CGEnv -> SSEnv -> IO a 
evalSM act tgt fcfg cgi cgenv env = do 
  ctx <- SMT.makeContext fcfg tgt  
  r <- evalStateT act (SState env 0 ctx cgi cgenv fcfg 0)
  SMT.cleanupContext ctx 
  return r 

getSEnv :: SM SSEnv
getSEnv = ssEnv <$> get 


addsEnv :: [(Var, SpecType)] -> SM () 
addsEnv xts = 
  mapM_ (\(x,t) -> modify (\s -> s {ssEnv = M.insert (symbol x) (t,x) (ssEnv s)})) xts  


addEnv :: Var -> SpecType -> SM ()
addEnv x t = do 
  liftCG (\γ -> γ += ("arg", symbol x, t))
  modify (\s -> s {ssEnv = M.insert (symbol x) (t,x) (ssEnv s)}) 


liftCG :: (CGEnv -> CG CGEnv) -> SM () 
liftCG act = do 
  st <- get 
  let (cgenv, cgi) = runState (act (sCGEnv st)) (sCGI st) 
  modify (\s -> s {sCGI = cgi, sCGEnv = cgenv}) 



freshVar :: SpecType -> SM Var
freshVar t = (\i -> mkVar (Just "x") i (toType t)) <$> incrSM

incrDepth :: SM Int 
incrDepth = do s <- get 
               put s{sDepth = sDepth s + 1}
               return (sDepth s)


incrSM :: SM Int 
incrSM = do s <- get 
            put s{ssIdx = ssIdx s + 1}
            return (ssIdx s)

-- The rest will be added when needed.
-- Replaces    | old w   | new  | symbol name in expr.
substInFExpr :: Symbol -> Symbol -> Expr -> Expr
substInFExpr pn nn e = subst1 e (pn, EVar nn)

-------------------------------------------------------------------------------
-- | Misc ---------------------------------------------------------------------
-------------------------------------------------------------------------------

pprintMany :: (PPrint a) => [a] -> Doc
pprintMany xs = vcat [ F.pprint x $+$ text " " | x <- xs ]
