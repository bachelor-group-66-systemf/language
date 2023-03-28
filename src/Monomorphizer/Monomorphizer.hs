{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

module Monomorphizer.Monomorphizer (monomorphize) where

import           Data.Coerce                   (coerce)

import qualified Monomorphizer.MonomorphizerIr as M
import qualified TypeChecker.TypeCheckerIr     as T
import           TypeChecker.TypeCheckerIr     (Ident (..))

monomorphize :: T.Program -> M.Program
monomorphize (T.Program ds) = M.Program $ monoDefs ds

monoDefs :: [T.Def] -> [M.Def]
monoDefs = map monoDef

monoDef :: T.Def -> M.Def
monoDef (T.DBind bind) = M.DBind $ monoBind bind
monoDef (T.DData d)    = M.DData $ monoData d

monoBind :: T.Bind -> M.Bind
monoBind (T.Bind name args (e, t)) = M.Bind (monoId name) (map monoId args) (monoExpr e, monoType t)

monoData :: T.Data -> M.Data
monoData (T.Data id cs) = M.Data (monoType id) (map monoConstructor cs)

monoConstructor :: T.Inj -> M.Inj
monoConstructor (T.Inj (Ident i) t) = M.Inj (T.Ident i) (monoType t)

monoExpr :: T.Exp -> M.Exp
monoExpr = \case
    T.EVar i           -> M.EVar i
    T.ELit lit         -> M.ELit $ monoLit lit
    T.ELet bind expt   -> M.ELet (monoBind bind) (monoexpt expt)
    T.EApp expt1 expt2 -> M.EApp (monoexpt expt1) (monoexpt expt2)
    T.EAdd expt1 expt2 -> M.EAdd (monoexpt expt1) (monoexpt expt2)
    T.EAbs _i _expt    -> error "BUG"
    T.ECase expt injs  -> M.ECase (monoexpt expt) (monoInjs injs)
    T.EInj i           -> M.EVar i

monoAbsType :: T.Type -> M.Type
monoAbsType (T.TLit u)     = M.TLit (coerce u)
monoAbsType (T.TVar _v)    = M.TLit "Int"
monoAbsType (T.TAll _v _t) = error "NOT ALL TYPES"
monoAbsType (T.TFun t1 t2) = M.TFun (monoAbsType t1) (monoAbsType t2)
monoAbsType (T.TData _ _)  = error "NOT INDEXED TYPES"

monoType :: T.Type -> M.Type
monoType (T.TAll _ t)          = monoType t
monoType (T.TVar (T.MkTVar i)) = M.TLit "Int"
monoType (T.TLit (Ident i))    = M.TLit (T.Ident i)
monoType (T.TFun t1 t2)        = M.TFun (monoType t1) (monoType t2)
monoType (T.TData (Ident n) t) = M.TLit (T.Ident (n ++ concatMap show t))

monoexpt :: T.ExpT -> M.ExpT
monoexpt (e, t) = (monoExpr e, monoType t)

monoId :: T.Id -> M.Id
monoId (n, t) = (coerce n, monoType t)

monoLit :: T.Lit -> M.Lit
monoLit (T.LInt i)  = M.LInt i
monoLit (T.LChar c) = M.LChar c

monoInjs :: [T.Branch] -> [M.Branch]
monoInjs = map monoInj

monoInj :: T.Branch -> M.Branch
monoInj (T.Branch (patt, t) expt) = M.Branch (monoPattern patt, monoType t) (monoexpt expt)

monoPattern :: T.Pattern -> M.Pattern
monoPattern (T.PVar (id, t))    = M.PVar (id, monoType t)
monoPattern (T.PLit (lit, t))   = M.PLit (monoLit lit, monoType t)
monoPattern (T.PInj id ps)      = M.PInj (coerce id) (map monoPattern ps)
-- DO NOT DO THIS FOR REAL THOUGH
monoPattern (T.PEnum (Ident i)) = M.PInj (T.Ident i) []
monoPattern T.PCatch            = M.PCatch