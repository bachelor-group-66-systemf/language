{-# LANGUAGE LambdaCase #-}

module Main where

import           Codegen.Codegen             (generateCode)
import           Data.Bool                   (bool)
import           GHC.IO.Handle.Text          (hPutStrLn)
import           Grammar.ErrM                (Err)
import           Grammar.Par                 (myLexer, pProgram)
import           Grammar.Print               (printTree)

import           Monomorphizer.Monomorphizer (monomorphize)

import           Compiler                    (compile)
import           Control.Monad               (when)
import           Data.List.Extra             (isSuffixOf)
import           GHC.IO.Handle.Text          (hPutStrLn)
import           Grammar.ErrM                (Err)
import           Grammar.Par                 (myLexer, pProgram)
import           Grammar.Print               (printTree)
import           Renamer.Renamer             (rename)
import           System.Directory            (createDirectory, doesPathExist,
                                              getDirectoryContents,
                                              removeDirectoryRecursive,
                                              setCurrentDirectory)
import           System.Environment          (getArgs)
import           System.Exit                 (ExitCode, exitFailure,
                                              exitSuccess)
import           System.IO                   (stderr)
import           System.Process.Extra        (readCreateProcess, shell,
                                              spawnCommand, waitForProcess)
import           TypeChecker.TypeChecker     (typecheck)

-- import           Interpreter        (interpret)
import           LambdaLifter                (lambdaLift)
import           Renamer.Renamer             (rename)
import           System.Environment          (getArgs)
import           System.Exit                 (exitFailure, exitSuccess)
import           System.IO                   (stderr)
import           TypeChecker.RemoveTEVar     (RemoveTEVar (rmTEVar))
import           TypeChecker.TypeChecker     (typecheck)

main :: IO ()
main =
    getArgs >>= \case
        []             -> print "Required file path missing"
        ("-d" : s : _) -> main' True s
        (s : _)        -> main' False s

main' :: Bool -> String -> IO ()
main' debug s = do
    file <- readFile s

    printToErr "-- Parse Tree -- "
    parsed <- fromSyntaxErr . pProgram $ myLexer file
    bool (printToErr $ printTree parsed) (printToErr $ show parsed) debug

    printToErr "\n-- Renamer --"
    renamed <- fromRenamerErr . rename $ parsed
    bool (printToErr $ printTree renamed) (printToErr $ show renamed) debug

    printToErr "\n-- TypeChecker --"
    typechecked <- fromTypeCheckerErr $ typecheck renamed
    bool (printToErr $ printTree typechecked) (printToErr $ show typechecked) debug

    printToErr "\n-- Lambda Lifter --"
    let lifted = lambdaLift typechecked
    printToErr $ printTree lifted

    printToErr "\n -- Compiler --"
    generatedCode <- fromCompilerErr $ generateCode (monomorphize typechecked)
    putStrLn generatedCode

    check <- doesPathExist "output"
    when check (removeDirectoryRecursive "output")
    createDirectory "output"
    when debug $ do
        writeFile "output/llvm.ll" generatedCode
        debugDotViz

    compile generatedCode
    spawnWait "./hello_world"


    -- interpred <- fromInterpreterErr $ interpret lifted
    -- putStrLn "\n-- interpret"
    -- print interpred

    exitSuccess

debugDotViz :: IO ()
debugDotViz = do
    setCurrentDirectory "output"
    spawnWait "opt -dot-cfg llvm.ll -disable-output"
    content <- filter (isSuffixOf ".dot") <$> getDirectoryContents "."
    let commands = (\p -> "dot " <> p <> " -Tpng -o" <> p <> ".png") <$> content
    mapM_ spawnWait commands
    setCurrentDirectory ".."
    return ()

spawnWait :: String -> IO ExitCode
spawnWait s = spawnCommand s >>= waitForProcess
printToErr :: String -> IO ()
printToErr = hPutStrLn stderr

fromCompilerErr :: Err a -> IO a
fromCompilerErr =
    either
        ( \err -> do
            putStrLn "\nCOMPILER ERROR"
            putStrLn err
            exitFailure
        )
        pure

fromSyntaxErr :: Err a -> IO a
fromSyntaxErr =
    either
        ( \err -> do
            putStrLn "\nSYNTAX ERROR"
            putStrLn err
            exitFailure
        )
        pure

fromTypeCheckerErr :: Err a -> IO a
fromTypeCheckerErr =
    either
        ( \err -> do
            putStrLn "\nTYPECHECKER ERROR"
            putStrLn err
            exitFailure
        )
        pure

fromRenamerErr :: Err a -> IO a
fromRenamerErr =
    either
        ( \err -> do
            putStrLn "\nRENAMER ERROR"
            putStrLn err
            exitFailure
        )
        pure

fromInterpreterErr :: Err a -> IO a
fromInterpreterErr =
    either
        ( \err -> do
            putStrLn "\nINTERPRETER ERROR"
            putStrLn err
            exitFailure
        )
        pure
