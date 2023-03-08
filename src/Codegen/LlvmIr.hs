{-# LANGUAGE LambdaCase #-}

module Codegen.LlvmIr (
    LLVMType (..),
    LLVMIr (..),
    llvmIrToString,
    LLVMValue (..),
    LLVMComp (..),
    Visibility (..),
    CallingConvention (..)
) where

import           Data.List                 (intercalate)
import           TypeChecker.TypeCheckerIr

data CallingConvention = TailCC | FastCC | CCC | ColdCC
instance Show CallingConvention where
    show :: CallingConvention -> String
    show TailCC = "tailcc"
    show FastCC = "fastcc"
    show CCC    = "ccc"
    show ColdCC = "coldcc"

-- | A datatype which represents some basic LLVM types
data LLVMType
    = I1
    | I8
    | I32
    | I64
    | Ptr
    | Ref LLVMType
    | Function LLVMType [LLVMType]
    | Array Integer LLVMType
    | CustomType Ident

instance Show LLVMType where
    show :: LLVMType -> String
    show = \case
        I1 -> "i1"
        I8 -> "i8"
        I32 -> "i32"
        I64 -> "i64"
        Ptr -> "ptr"
        Ref ty -> show ty <> "*"
        Function t xs -> show t <> " (" <> intercalate ", " (map show xs) <> ")*"
        Array n ty -> concat ["[", show n, " x ", show ty, "]"]
        CustomType (Ident ty) -> "%" <> ty

data LLVMComp
    = LLEq
    | LLNe
    | LLUgt
    | LLUge
    | LLUlt
    | LLUle
    | LLSgt
    | LLSge
    | LLSlt
    | LLSle
instance Show LLVMComp where
    show :: LLVMComp -> String
    show = \case
        LLEq  -> "eq"
        LLNe  -> "ne"
        LLUgt -> "ugt"
        LLUge -> "uge"
        LLUlt -> "ult"
        LLUle -> "ule"
        LLSgt -> "sgt"
        LLSge -> "sge"
        LLSlt -> "slt"
        LLSle -> "sle"

data Visibility = Local | Global
instance Show Visibility where
    show :: Visibility -> String
    show Local  = "%"
    show Global = "@"

-- | Represents a LLVM "value", as in an integer, a register variable,
-- or a string contstant
data LLVMValue
    = VInteger Integer
    | VIdent Ident LLVMType
    | VConstant String
    | VFunction Ident Visibility LLVMType

instance Show LLVMValue where
    show :: LLVMValue -> String
    show v = case v of
        VInteger i                -> show i
        VIdent (Ident n) _        -> "%" <> n
        VFunction (Ident n) vis _ -> show vis <> n
        VConstant s               -> "c" <> show s

type Params = [(Ident, LLVMType)]
type Args = [(LLVMType, LLVMValue)]

-- | A datatype which represents different instructions in LLVM
data LLVMIr
    = Type Ident [LLVMType]
    | Define CallingConvention LLVMType Ident Params
    | DefineEnd
    | Declare LLVMType Ident Params
    | SetVariable Ident LLVMIr
    | Variable Ident
    | GetElementPtrInbounds LLVMType LLVMType LLVMValue LLVMType LLVMValue LLVMType LLVMValue
    | Add LLVMType LLVMValue LLVMValue
    | Sub LLVMType LLVMValue LLVMValue
    | Div LLVMType LLVMValue LLVMValue
    | Mul LLVMType LLVMValue LLVMValue
    | Srem LLVMType LLVMValue LLVMValue
    | Icmp LLVMComp LLVMType LLVMValue LLVMValue
    | Br Ident
    | BrCond LLVMValue Ident Ident
    | Label Ident
    | Call CallingConvention LLVMType Visibility Ident Args
    | Alloca LLVMType
    | Store LLVMType LLVMValue LLVMType Ident
    | Load LLVMType LLVMType Ident
    | Bitcast LLVMType Ident LLVMType
    | Ret LLVMType LLVMValue
    | Comment String
    | UnsafeRaw String -- This should generally be avoided, and proper
    -- instructions should be used in its place
    deriving (Show)

-- | Converts a list of LLVMIr instructions to a string
llvmIrToString :: [LLVMIr] -> String
llvmIrToString = go 0
  where
    go :: Int -> [LLVMIr] -> String
    go _ [] = mempty
    go i (x : xs) = do
        let (i', n) = case x of
                Define{}  -> (i + 1, 0)
                DefineEnd -> (i - 1, 0)
                _         -> (i, i)
        insToString n x <> go i' xs

{- | Converts a LLVM inststruction to a String, allowing for printing etc.
  The integer represents the indentation
-}
{- FOURMOLU_DISABLE -}
    insToString :: Int -> LLVMIr -> String
    insToString i l =
        replicate i '\t' <> case l of
            (GetElementPtrInbounds t1 t2 p t3 v1 t4 v2) -> do
                -- getelementptr inbounds %Foo, %Foo* %x, i32 0, i32 0
                concat
                    [ "getelementptr inbounds ", show t1, ", " , show t2
                    , " ", show p, ", ", show t3, " ", show v1,
                    ", ", show t4, " ", show v2, "\n" ]
            (Type (Ident n) types) ->
                concat
                    [ "%", n, " = type { "
                    , intercalate ", " (map show types)
                    , " }\n"
                    ]
            (Define c t (Ident i) params) ->
                concat
                    [ "define ", show c, " ", show t, " @", i
                    , "(", intercalate ", " (map (\(Ident y, x) -> unwords [show x, "%" <> y]) params)
                    , ") {\n"
                    ]
            DefineEnd -> "}\n"
            (Declare _t (Ident _i) _params) -> undefined
            (SetVariable (Ident i) ir) -> concat ["%", i, " = ", insToString 0 ir]
            (Add t v1 v2) ->
                concat
                    [ "add ", show t, " ", show v1
                    , ", ", show v2, "\n"
                    ]
            (Sub t v1 v2) ->
                concat
                    [ "sub ", show t, " ", show v1, ", "
                    , show v2, "\n"
                    ]
            (Div t v1 v2) ->
                concat
                    [ "sdiv ", show t, " ", show v1, ", "
                    , show v2, "\n"
                    ]
            (Mul t v1 v2) ->
                concat
                    [ "mul ", show t, " ", show v1
                    , ", ", show v2, "\n"
                    ]
            (Srem t v1 v2) ->
                concat
                    [ "srem ", show t, " ", show v1, ", "
                    , show v2, "\n"
                    ]
            (Call c t vis (Ident i) arg) ->
                concat
                    [ "call ", show c, " ",  show t, " ", show vis, i, "("
                    , intercalate ", " $ Prelude.map (\(x, y) -> show x <> " " <> show y) arg
                    , ")\n"
                    ]
            (Alloca t) -> unwords ["alloca", show t, "\n"]
            (Store t1 val t2 (Ident id2)) ->
                concat
                    [ "store ", show t1, " ", show val
                    , ", ", show t2 , " %", id2, "\n"
                    ]
            (Load t1 t2 (Ident addr)) ->
                concat
                    [ "load ", show t1, ", "
                    , show t2, " %", addr, "\n"
                    ]
            (Bitcast t1 (Ident i) t2) ->
                concat
                    [ "bitcast ", show t1, " %"
                    , i, " to ", show t2, "\n"
                    ]
            (Icmp comp t v1 v2) ->
                concat
                    [ "icmp ", show comp, " ", show t
                    , " ", show v1, ", ", show v2, "\n"
                    ]
            (Ret t v) ->
                concat
                    [ "ret ", show t, " "
                    , show v, "\n"
                    ]
            (UnsafeRaw s) -> s
            (Label (Ident s)) -> "\n" <> lblPfx <> s <> ":\n"
            (Br (Ident s)) -> "br label %" <> lblPfx <> s <> "\n"
            (BrCond val (Ident s1) (Ident s2)) ->
                concat
                    [ "br i1 ", show val, ", ", "label %"
                    , lblPfx, s1, ", ", "label %", lblPfx, s2, "\n"
                    ]
            (Comment s) -> "; " <> s <> "\n"
            (Variable (Ident id)) -> "%" <> id
{- FOURMOLU_ENABLE -}

lblPfx :: String
lblPfx = "lbl_"