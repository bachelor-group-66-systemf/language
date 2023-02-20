{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

module Compiler (compile) where

import           Auxiliary           (snoc)
import           Control.Monad.State (StateT, execStateT, gets, modify)
import           Data.Map            (Map)
import qualified Data.Map            as Map
import           Data.Tuple.Extra    (dupe, first, second)
import qualified Grammar.Abs         as GA
import           Grammar.ErrM        (Err)
import           LlvmIr              (LLVMComp (..), LLVMIr (..), LLVMType (..),
                                      LLVMValue (..), Visibility (..),
                                      llvmIrToString)
import           TypeChecker         (partitionType)
import           TypeCheckerIr       (Bind (..), Case (..), Exp (..), Id,
                                      Ident (..), Program (..),
                                      Type (TFun, TInt))

-- | The record used as the code generator state
data CodeGenerator = CodeGenerator
    { instructions  :: [LLVMIr]
    , functions     :: Map Id FunctionInfo
    , variableCount :: Integer
    , labelCount    :: Integer
    }

-- | A state type synonym
type CompilerState a = StateT CodeGenerator Err a

data FunctionInfo = FunctionInfo
    { numArgs   :: Int
    , arguments :: [Id]
    }

-- | Adds a instruction to the CodeGenerator state
emit :: LLVMIr -> CompilerState ()
emit l = modify $ \t -> t { instructions = Auxiliary.snoc l $ instructions t }

-- | Increases the variable counter in the CodeGenerator state
increaseVarCount :: CompilerState ()
increaseVarCount = modify $ \t -> t { variableCount = variableCount t + 1 }

-- | Returns the variable count from the CodeGenerator state
getVarCount :: CompilerState Integer
getVarCount = gets variableCount

-- | Increases the variable count and returns it from the CodeGenerator state
getNewVar :: CompilerState Integer
getNewVar = increaseVarCount >> getVarCount

-- | Increses the label count and returns a label from the CodeGenerator state
getNewLabel :: CompilerState Integer
getNewLabel = do
    modify (\t -> t{labelCount = labelCount t + 1})
    gets labelCount

-- | Produces a map of functions infos from a list of binds,
--  which contains useful data for code generation.
getFunctions :: [Bind] -> Map Id FunctionInfo
getFunctions bs = Map.fromList $ map go bs
  where
    go (Bind id args _) =
        (id, FunctionInfo { numArgs=length args, arguments=args })



initCodeGenerator :: [Bind] -> CodeGenerator
initCodeGenerator scs = CodeGenerator { instructions = defaultStart
                                      , functions = getFunctions scs
                                      , variableCount = 0
                                      , labelCount = 0
                                      }
{-
run :: Err String -> IO ()
run s = do
    let s' = case s of
            Right s -> s
            Left _  -> error "yo"
    writeFile "llvm.ll" s'
    putStrLn . trim =<< readCreateProcess (shell "lli") s'

test :: Integer -> Program
test v = Program [
    Bind (Ident "fibonacci", TInt) [(Ident "x", TInt)] (
        ECase TInt (EId ("x", TInt)) [
            (TInt,Case (CInt 0) (EInt 0)),
            Case (CInt 1) (EInt 1),
            Case CatchAll (EAdd TInt
                (EApp TInt (EId (Ident "fibonacci", TInt)) (
                    EAdd TInt (EId (Ident "x", TInt))
                              (EInt (fromIntegral ((maxBound :: Int) * 2)))
                ))
                (EApp TInt (EId (Ident "fibonacci", TInt)) (
                    EAdd TInt (EId (Ident "x", TInt))
                    (EInt (fromIntegral ((maxBound :: Int) * 2 + 1)))
                ))
            )
        ]
    ),
    Bind (Ident "main", TInt) [] (
       EApp TInt (EId (Ident "fibonacci", TInt))  (EInt v) -- (EInt 92)
    )
    ]
-}
{- | Compiles an AST and produces a LLVM Ir string.
  An easy way to actually "compile" this output is to
  Simply pipe it to LLI
-}
compile :: Program -> Err String
compile (Program scs) = do
    let codegen = initCodeGenerator scs
    llvmIrToString . instructions <$> execStateT (compileScs scs) codegen

compileScs :: [Bind] -> CompilerState ()
compileScs []                             = pure ()
compileScs (Bind (name, t) args exp : xs) = do
    emit $ UnsafeRaw "\n"
    emit . Comment $ show name <> ": " <> show exp
    let args' = map (second type2LlvmType) args
    emit $ Define I64 {-(type2LlvmType t_return)-} name args'
    functionBody <- exprToValue exp
    if name == "main"
        then mapM_ emit $ mainContent functionBody
        else emit $ Ret I64 functionBody
    emit DefineEnd
    modify $ \s -> s { variableCount = 0 }
    compileScs xs
  where
    t_return = snd $ partitionType (length args) t

mainContent :: LLVMValue -> [LLVMIr]
mainContent var =
    [ UnsafeRaw $
        "call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef " <> show var <> ")\n"
    , -- , SetVariable (Ident "p") (Icmp LLEq I64 (VInteger 2) (VInteger 2))
      -- , BrCond (VIdent (Ident "p")) (Ident "b_1") (Ident "b_2")
      -- , Label (Ident "b_1")
      -- , UnsafeRaw
      --     "call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef 1)\n"
      -- , Br (Ident "end")
      -- , Label (Ident "b_2")
      -- , UnsafeRaw
      --     "call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef 2)\n"
      -- , Br (Ident "end")
      -- , Label (Ident "end")
      Ret I64 (VInteger 0)
    ]

defaultStart :: [LLVMIr]
defaultStart = [ UnsafeRaw "@.str = private unnamed_addr constant [3 x i8] c\"%i\n\", align 1\n"
               , UnsafeRaw "declare i32 @printf(ptr noalias nocapture, ...)\n"
               ]

compileExp :: Exp -> CompilerState ()
compileExp (EInt int)      = emitInt int
compileExp (EAdd t e1 e2)  = emitAdd t e1 e2
compileExp (ESub t e1 e2)  = emitSub t e1 e2
compileExp (EId (name, _)) = emitIdent name
compileExp (EApp t e1 e2)  = emitApp t e1 e2
compileExp (EAbs t ti e)   = emitAbs t ti e
compileExp (ELet binds e)  = emitLet binds e
compileExp (ECase t e cs)  = emitECased t e cs
    -- go (EMul e1 e2)  = emitMul e1 e2
    -- go (EDiv e1 e2)  = emitDiv e1 e2
    -- go (EMod e1 e2)  = emitMod e1 e2

--- aux functions ---
emitECased :: Type -> Exp -> [(Type, Case)] -> CompilerState ()
emitECased t e cases = do
    let cs = snd <$> cases
    let ty = type2LlvmType t
    vs <- exprToValue e
    lbl <- getNewLabel
    let label = Ident $ "escape_" <> show lbl
    stackPtr <- getNewVar
    emit $ SetVariable (Ident $ show stackPtr) (Alloca ty)
    mapM_ (emitCases ty label stackPtr vs) cs
    emit $ Label label
    res <- getNewVar
    emit $ SetVariable (Ident $ show res) (Load ty Ptr (Ident $ show stackPtr))
    where
    emitCases :: LLVMType -> Ident -> Integer -> LLVMValue -> Case -> CompilerState ()
    emitCases ty label stackPtr vs (Case (GA.CInt i) exp) = do
        ns <- getNewVar
        lbl_fail <- getNewLabel
        lbl_succ <- getNewLabel
        let failed = Ident $ "failed_" <> show lbl_fail
        let success = Ident $ "success_" <> show lbl_succ
        emit $ SetVariable (Ident $ show ns) (Icmp LLEq ty vs (VInteger i))
        emit $ BrCond (VIdent (Ident $ show ns) ty) success failed
        emit $ Label success
        val <- exprToValue exp
        emit $ Store ty val Ptr (Ident . show $ stackPtr)
        emit $ Br label
        emit $ Label failed
    emitCases ty label stackPtr  _ (Case GA.CatchAll exp) = do
        val <- exprToValue exp
        emit $ Store ty val Ptr (Ident . show $ stackPtr)
        emit $ Br label


emitAbs :: Type -> Id -> Exp -> CompilerState ()
emitAbs _t tid e = do
    emit . Comment $
        "Lambda escaped previous stages: \\" <> show tid <> " . " <> show e
emitLet :: Bind -> Exp -> CompilerState ()
emitLet xs e = do
    emit $
        Comment $
            concat
                [ "ELet ("
                , show xs
                , " = "
                , show e
                , ") is not implemented!"
                ]

emitApp :: Type -> Exp -> Exp -> CompilerState ()
emitApp t e1 e2 = appEmitter t e1 e2 []
  where
    appEmitter :: Type -> Exp -> Exp -> [Exp] -> CompilerState ()
    appEmitter t e1 e2 stack = do
        let newStack = e2 : stack
        case e1 of
            EApp _ e1' e2' -> appEmitter t e1' e2' newStack
            EId id@(name, _) -> do
                args <- traverse exprToValue newStack
                vs <- getNewVar
                funcs <- gets functions
                let visibility = maybe Local (const Global) $ Map.lookup id funcs
                    args'      = map (first valueGetType . dupe) args
                    call       = Call (type2LlvmType t) visibility name args'
                emit $ SetVariable (Ident $ show vs) call
            x -> do
                emit . Comment $ "The unspeakable happened: "
                emit . Comment $ show x

emitIdent :: Ident -> CompilerState ()
emitIdent id = do
    -- !!this should never happen!!
    emit $ Comment "This should not have happened!"
    emit $ Variable id
    emit $ UnsafeRaw "\n"

emitInt :: Integer -> CompilerState ()
emitInt i = do
    -- !!this should never happen!!
    varCount <- getNewVar
    emit $ Comment "This should not have happened!"
    emit $ SetVariable (Ident (show varCount)) (Add I64 (VInteger i) (VInteger 0))

emitAdd :: Type -> Exp -> Exp -> CompilerState ()
emitAdd t e1 e2 = do
    v1 <- exprToValue e1
    v2 <- exprToValue e2
    v <- getNewVar
    emit $ SetVariable (Ident $ show v) (Add (type2LlvmType t) v1 v2)

emitSub :: Type -> Exp -> Exp -> CompilerState ()
emitSub t e1 e2 = do
    v1 <- exprToValue e1
    v2 <- exprToValue e2
    v <- getNewVar
    emit $ SetVariable (Ident $ show v) (Sub (type2LlvmType t) v1 v2)

-- emitMul :: Exp -> Exp -> CompilerState ()
-- emitMul e1 e2 = do
--     (v1,v2) <- binExprToValues e1 e2
--     increaseVarCount
--     v <- gets variableCount
--     emit $ SetVariable $ Ident $ show v
--     emit $ Mul I64 v1 v2

-- emitMod :: Exp -> Exp -> CompilerState ()
-- emitMod e1 e2 = do
--     -- `let m a b = rem (abs $ b + a) b`
--     (v1,v2) <- binExprToValues e1 e2
--     increaseVarCount
--     vadd <- gets variableCount
--     emit $ SetVariable $ Ident $ show vadd
--     emit $ Add I64 v1 v2
--
--     increaseVarCount
--     vabs <- gets variableCount
--     emit $ SetVariable $ Ident $ show vabs
--     emit $ Call I64 (Ident "llvm.abs.i64")
--         [ (I64, VIdent (Ident $ show vadd))
--         , (I1, VInteger 1)
--         ]
--     increaseVarCount
--     v <- gets variableCount
--     emit $ SetVariable $ Ident $ show v
--     emit $ Srem I64 (VIdent (Ident $ show vabs)) v2

-- emitDiv :: Exp -> Exp -> CompilerState ()
-- emitDiv e1 e2 = do
--     (v1,v2) <- binExprToValues e1 e2
--     increaseVarCount
--     v <- gets variableCount
--     emit $ SetVariable $ Ident $ show v
--     emit $ Div I64 v1 v2

exprToValue :: Exp -> CompilerState LLVMValue
exprToValue = \case
    EInt i -> pure $ VInteger i

    EId id@(name, t) -> do
        funcs <- gets functions
        case Map.lookup id funcs of
            Just fi -> do
                if numArgs fi == 0
                    then do
                        vc <- getNewVar
                        emit $ SetVariable (Ident $ show vc)
                            (Call (type2LlvmType t) Global name [])
                        pure $ VIdent (Ident $ show vc) (type2LlvmType t)
                    else pure $ VFunction name Global (type2LlvmType t)
            Nothing -> pure $ VIdent name (type2LlvmType t)

    e -> do
        compileExp e
        v <- getVarCount
        pure $ VIdent (Ident $ show v) (getType e)

type2LlvmType :: Type -> LLVMType
type2LlvmType = \case
    TInt -> I64
    TFun t xs -> do
        let (t', xs') = function2LLVMType xs [type2LlvmType t]
        Function t' xs'
    t -> CustomType $ Ident ("\"" ++ show t ++ "\"")
  where
    function2LLVMType :: Type -> [LLVMType] -> (LLVMType, [LLVMType])
    function2LLVMType (TFun t xs) s = function2LLVMType xs (type2LlvmType t : s)
    function2LLVMType x s           = (type2LlvmType x, s)

getType :: Exp -> LLVMType
getType (EInt _)      = I64
getType (EAdd t _ _)  = type2LlvmType t
getType (ESub t _ _)  = type2LlvmType t
getType (EId (_, t))  = type2LlvmType t
getType (EApp t _ _)  = type2LlvmType t
getType (EAbs t _ _)  = type2LlvmType t
getType (ELet _ e)    = getType e
getType (ECase t _ _) = type2LlvmType t

valueGetType :: LLVMValue -> LLVMType
valueGetType (VInteger _)      = I64
valueGetType (VIdent _ t)      = t
valueGetType (VConstant s)     = Array (length s) I8
valueGetType (VFunction _ _ t) = t
