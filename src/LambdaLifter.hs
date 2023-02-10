{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}


module LambdaLifter (lambdaLift, freeVars, abstract, rename, collectScs) where

import           Data.List        (mapAccumL)
import           Data.Map         (Map)
import qualified Data.Map         as Map
import           Data.Maybe       (fromMaybe)
import           Data.Set         (Set, (\\))
import qualified Data.Set         as Set
import           Data.Tuple.Extra (uncurry3)
import           Grammar.Abs
import           Prelude          hiding (exp)



-- | Lift lambdas and let expression into supercombinators.
lambdaLift :: Program -> Program
lambdaLift = collectScs . rename . abstract . freeVars


-- | Annotate free variables
freeVars :: Program -> AnnProgram
freeVars (Program ds) = [ (n, xs, freeVarsExp (Set.fromList xs) e)
                        | Bind n xs e <- ds
                        ]

freeVarsExp :: Set Ident -> Exp -> AnnExp
freeVarsExp lv = \case

  EId n | Set.member n lv -> (Set.singleton n, AId n)
        | otherwise       -> (mempty, AId n)

  EInt i     -> (mempty, AInt i)

  EApp e1 e2 -> (Set.union (freeVarsOf e1') (freeVarsOf e2'), AApp e1' e2')
    where e1' = freeVarsExp lv e1
          e2' = freeVarsExp lv e2

  EAdd e1 e2 -> (Set.union (freeVarsOf e1') (freeVarsOf e2'), AAdd e1' e2')
    where e1' = freeVarsExp lv e1
          e2' = freeVarsExp lv e2

  EAbs n  e  -> (Set.delete n $ freeVarsOf e', AAbs n e')
    where e'  = freeVarsExp (Set.insert n lv) e

  ELet bs e  -> (Set.union bsFree eFree, ALet bs' e')
    where
      bsFree       = freeInValues \\ nsSet
      eFree        = freeVarsOf e' \\ nsSet
      bs'          = zipWith3 ABind ns xs es'
      e'           = freeVarsExp e_lv e
      (ns, xs, es) = fromBinders bs
      nsSet        = Set.fromList ns
      e_lv         = Set.union lv nsSet
      es'          = map (freeVarsExp e_lv) es
      freeInValues = foldr1 Set.union (map freeVarsOf es')


freeVarsOf :: AnnExp -> Set Ident
freeVarsOf = fst

fromBinders :: [Bind] -> ([Ident], [[Ident]], [Exp])
fromBinders bs = unzip3 [ (n, xs, e) | Bind n xs e <- bs ]

-- AST annotated with free variables
type AnnProgram = [(Ident, [Ident], AnnExp)]

type AnnExp = (Set Ident, AnnExp')

data ABind = ABind Ident [Ident] AnnExp deriving Show

data AnnExp' = AId Ident
             | AInt Integer
             | AApp AnnExp  AnnExp
             | AAdd AnnExp  AnnExp
             | AAbs Ident   AnnExp
             | ALet [ABind] AnnExp
             deriving Show

-- | Lift lambdas to let expression of the form @let sc = \x -> rhs@
abstract :: AnnProgram -> Program
abstract prog = Program $ map f prog
  where
  f :: (Ident, [Ident], AnnExp) -> Bind
  f (name, pars, rhs@(_, e)) =
    case e of
      AAbs par body -> Bind name (snoc par pars) $ abstractExp body
      _             -> Bind name pars            $ abstractExp rhs

abstractExp :: AnnExp -> Exp
abstractExp (free, exp) = case exp of
  AId  n     -> EId n
  AInt i     -> EInt i
  AApp e1 e2 -> EApp (abstractExp e1) (abstractExp e2)
  AAdd e1 e2 -> EAdd (abstractExp e1) (abstractExp e2)
  ALet bs e  -> ELet [Bind n xs (abstractExp e1) | ABind n xs e1 <- bs ] $ abstractExp e
  AAbs n  e  -> foldl EApp sc (map EId fvList)
    where
      fvList = Set.toList free
      bind = Bind "sc" [] e'
      e' = foldr EAbs (abstractExp e) (fvList ++ [n])
      sc = ELet [bind] (EId (Ident "sc"))


snoc :: a -> [a] -> [a]
snoc x xs = xs ++ [x]

-- | Rename all supercombinators and variables
rename :: Program -> Program
rename (Program ds) = Program $ map (uncurry3 Bind) tuples
  where
    tuples = snd (mapAccumL renameSc 0 ds)
    renameSc i (Bind n xs e) = (i2, (n, xs', e'))
      where
        (i1, xs', env) = newNames i xs
        (i2, e')       = renameExp env i1 e

renameExp :: Map Ident Ident -> Int -> Exp -> (Int, Exp)
renameExp env i = \case

  EId  n     -> (i, EId . fromMaybe n $ Map.lookup n env)

  EInt i1    -> (i, EInt i1)

  EApp e1 e2 -> (i2, EApp e1' e2')
    where
      (i1, e1') = renameExp env i e1
      (i2, e2') = renameExp env i1 e2

  EAdd e1 e2 -> (i2, EAdd e1' e2')
    where
      (i1, e1') = renameExp env i e1
      (i2, e2') = renameExp env i1 e2

  ELet bs e  -> (i3, ELet (zipWith3 Bind ns' xs es') e')
    where
      (i1, e')        = renameExp e_env i e
      (ns, xs, es)    = fromBinders bs
      (i2, ns', env') = newNames i1 ns
      e_env           = Map.union env' env
      (i3, es')       = mapAccumL (renameExp e_env) i2 es


  EAbs n  e  -> (i2, EAbs (head ns) e')
    where
      (i1, ns, env') = newNames i [n]
      (i2, e')       = renameExp (Map.union env' env ) i1 e


newNames :: Int -> [Ident] -> (Int, [Ident], Map Ident Ident)
newNames i old_names = (i', new_names, env)
  where
    (i', new_names) = getNames i old_names
    env = Map.fromList $ zip old_names new_names


getName :: Int -> Ident -> (Int, Ident)
getName i (Ident s) = (i + 1, makeName s i)

getNames :: Int -> [Ident] -> (Int, [Ident])
getNames i ns = (i + length ss, zipWith makeName ss [i..])
  where
    ss = map (\(Ident s) -> s) ns

makeName :: String -> Int -> Ident
makeName prefix i = Ident (prefix ++ "_" ++ show i)


-- | Collects supercombinators by lifting appropriate let expressions
collectScs :: Program -> Program
collectScs (Program ds) = Program $ concatMap collectOneSc ds
  where
    collectOneSc (Bind name args rhs) = Bind name args rhs' : scs
      where (scs, rhs') = collectScsExp rhs

collectScsExp :: Exp -> ([Bind], Exp)
collectScsExp = \case

  EId  n     -> ([], EId n)

  EInt i     -> ([], EInt i)

  EApp e1 e2 -> (scs1 ++ scs2, EApp e1' e2')
    where
      (scs1, e1') = collectScsExp e1
      (scs2, e2') = collectScsExp e2

  EAdd e1 e2 -> (scs1 ++ scs2, EAdd e1' e2')
    where
      (scs1, e1') = collectScsExp e1
      (scs2, e2') = collectScsExp e2

  EAbs x  e  -> (scs, EAbs x e')
    where
      (scs, e') = collectScsExp e

  ELet bs e  -> (rhss_scs ++ e_scs ++ local_scs, mkEAbs non_scs' e')
    where
      (rhss_scs, bs') = mapAccumL collectScs_d [] bs
      scs'            = [ Bind n xs rhs | Bind n xs rhs <- bs', isEAbs rhs]
      non_scs'        = [ Bind n xs rhs | Bind n xs rhs <- bs', not $ isEAbs rhs]
      local_scs       = [ Bind n (xs ++ [x]) e1 | Bind n xs (EAbs x e1) <- scs']
      (e_scs, e')     = collectScsExp e

      collectScs_d scs (Bind n xs rhs) = (scs ++ rhs_scs1, Bind n xs rhs')
        where
          (rhs_scs1, rhs') = collectScsExp rhs

isEAbs :: Exp -> Bool
isEAbs = \case
  EAbs {} -> True
  _       -> False

mkEAbs :: [Bind] -> Exp -> Exp
mkEAbs [] e = e
mkEAbs bs e = ELet bs e

