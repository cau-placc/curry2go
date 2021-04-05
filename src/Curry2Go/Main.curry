module Curry2Go.Main where

import Data.IORef
import Data.List             ( find, intercalate, last )
import System.Environment    ( getArgs )

import Control.Monad         ( unless, when )

import Data.Time             ( compareClockTime )
import FlatCurry.Types       ( Prog )
import FlatCurry.Files       ( readFlatCurryWithParseOptions
                             , readFlatCurryIntWithParseOptions )
import FlatCurry.Goodies     ( progImports, progName )
import Language.Go.Show      ( showGoProg )
import Language.Go.Types
import ICurry.Types
import ICurry.Compiler       ( flatCurry2ICurryWithProgs )
import ICurry.Options        ( ICOptions(..), defaultICOptions )
import System.CurryPath
import System.Console.GetOpt
import System.Directory
import System.FilePath
import System.Process        ( exitWith, system )
import System.FrontendExec

import CompilerStructure
import Curry2Go.Compiler
import Curry2Go.Config       ( compilerMajorVersion, compilerMinorVersion
                             , compilerRevisionVersion
                             , compilerName, lowerCompilerName
                             , curry2goDir, upperCompilerName )
import Curry2Go.PkgConfig    ( packagePath, packageVersion )

--- Implementation of CompStruct for the curry2go compiler.

--- Returns the filepath relative to curry2goDir where
--- the compiled version of the module `m` will be stored.
modPackage :: String -> String
modPackage m =
  combine (modNameToPath m) (last (splitModuleIdentifiers m) ++ ".go")

--- Creates the output path for a compiled Curry module.
createFilePath :: String -> IO String
createFilePath m = do
  path <- lookupModuleSourceInLoadPath m
  case path of
    Nothing       -> error ("Unknown module " ++ m)
    Just (dir, _) -> return (joinPath [dir, curry2goDir, modPackage m])

--- Gets the path to the source file of a Curry module.
getCurryPath :: String -> IO String
getCurryPath m =
  lookupModuleSourceInLoadPath m >>= \path -> case path of
    Nothing        -> error ("Unknown module " ++ m)
    Just (_, file) -> return file

--- Gets the base directory of a Curry module.
getBaseDirOfModule :: String -> IO String
getBaseDirOfModule m = do
  path <- lookupModuleSourceInLoadPath m
  case path of
    Nothing       -> error ("Unknown module " ++ m)
    Just (dir, _) -> return dir

--- Load a FlatCurry interface for a module if not already done.
loadInterface :: IORef [Prog] -> String -> IO Prog
loadInterface sref mname = do
  loadedints <- readIORef sref
  maybe (do int <- readFlatCurryIntWithParseOptions mname c2gFrontendParams
            writeIORef sref (int : loadedints)
            return int)
        return
        (find (\fp -> progName fp == mname) loadedints)

--- Gets the imported modules of a Curry module.
getCurryImports :: IORef [Prog] -> String -> IO [String]
getCurryImports sref mname = loadInterface sref mname >>= return . progImports

--- Loads an IProg from the name of a Curry module.
loadICurry :: IORef [Prog] -> String -> IO IProg
loadICurry sref mname = do
  prog  <- readFlatCurryWithParseOptions mname c2gFrontendParams
  impints <- mapM (loadInterface sref) (progImports prog)
  flatCurry2ICurryWithProgs c2gICOptions impints prog

-- The front-end parameters for Curry2Go.
c2gFrontendParams :: FrontendParams
c2gFrontendParams =
  setQuiet True $
  setDefinitions [curry2goDef] $
  setOutDir curry2goDir $
  defaultParams
 where
  curry2goDef = ("__" ++ upperCompilerName ++ "__",
                 compilerMajorVersion * 100 + compilerMinorVersion)

-- The ICurry compiler options for Curry2Go.
c2gICOptions :: ICOptions
c2gICOptions =
  defaultICOptions { optVerb = 0, optFrontendParams = c2gFrontendParams }

--- Copies external files that are in the include folder or
--- next to the source file into the directory with the
--- compiled version of a Curry module.
postProcess :: CGOptions -> String -> IO ()
postProcess opts mname = do
  let outPath = combine curry2goDir (modPackage mname)
      outDir  = takeDirectory outPath
  createDirectoryIfMissing True outDir
  fPath       <- getFilePath (goStruct opts) mname
  extFilePath <- getExtFilePath
  extInSource <- doesFileExist extFilePath
  let extFileName = takeFileName extFilePath
  if extInSource
    then copyIfNewer extFilePath (combine outDir extFileName)
    else do
      let c2gExtFile = packagePath </> "external_files" </> extFileName
      extInC2GInclude <- doesFileExist c2gExtFile
      when extInC2GInclude $
        copyIfNewer c2gExtFile (combine outDir extFileName)
  copyIfNewer fPath outPath
 where
  copyIfNewer source target = do
    alreadyExists <- doesFileExist target
    if alreadyExists
      then do
        sMod <- getModificationTime source
        tMod <- getModificationTime target
        when (compareClockTime sMod tMod == GT) $ showCopyFile source target
      else showCopyFile source target

  showCopyFile source target = do
    printVerb opts 3 $ "Copying '" ++ source ++ "' to '" ++ target ++ "'..."
    copyFile source target

  getExtFilePath = do
    path <- getCurryPath mname
    return $
      replaceFileName path
        (stripCurrySuffix (takeFileName path) ++ "_external.go")

--- The structure for the Curry2Go compilation process.
--- The compiler cache manages the list of already loaded FlatCurry interfaces
--- to avoid multiple readings.
goStruct :: CGOptions -> CompStruct IProg [Prog]
goStruct opts = defaultStruct
  { outputDir      = "."
  , filePath       = createFilePath
  , excludeModules = []
  , getProg        = loadICurry
  , getPath        = getCurryPath
  , getImports     = getCurryImports
  , postProc       = postProcess opts
  }

--- Implementation of compiler io.

--- main function
main :: IO ()
main = do
  args <- getArgs
  (opts, paths) <- processOptions args
  case paths of
    []  -> error "Input path missing!"
    [p] -> runModuleAction (curry2Go opts) (stripCurrySuffix p)
    _   -> error "Too many paths given!"

c2goBanner :: String
c2goBanner = unlines [bannerLine, bannerText, bannerLine]
 where
  bannerText = compilerName ++ " Compiler (Version " ++ packageVersion ++ ")"
  bannerLine = take (length bannerText) (repeat '-')

--- Compiles a curry program into a go program.
--- @param opts    - compiler options 
--- @param mainmod - name of main module
curry2Go :: CGOptions -> String -> IO ()
curry2Go opts mainmod = do
  printVerb opts 1 c2goBanner
  printVerb opts 1 $ "Compiling program '" ++ mainmod ++ "'..."
  -- read main FlatCurry in order to be sure that all imports are up-to-date
  fprog <- readFlatCurryWithParseOptions mainmod c2gFrontendParams
  sref <- newIORef []
  let gostruct = goStruct opts
  compile (gostruct {compProg = compileIProg2GoString opts}) sref
          (verbosity opts == 0) mainmod
  printVerb opts 2 $ "Go programs written to '" ++ outputDir gostruct ++ "'"
  impints <- mapM (loadInterface sref) (progImports fprog)
  IProg moduleName _ _ funcs <- flatCurry2ICurryWithProgs c2gICOptions impints
                                                          fprog
  when (genMain opts) $ do
    let mainprogname = removeDots moduleName ++ ".go"
    printVerb opts 1 $ "Generating main program '" ++ mainprogname ++ "'"
    let mainprog = showGoProg (createMainProg funcs (opts {modName = "main"}))
    printVerb opts 4 $ "Main Go program:\n\n" ++ mainprog
    let mainfile = combine curry2goDir mainprogname
    writeFile mainfile mainprog
    printVerb opts 2 $ "...written to " ++ mainfile
  when (genMain opts) $ do
    printVerb opts 1 "Creating executable..."
    let bcmd = "go build " ++
               combine curry2goDir (removeDots moduleName ++ ".go")
    printVerb opts 2 $ "...with command: " ++ bcmd
    i <- system bcmd
    when (i /= 0) $ error "Build failed!"
    printVerb opts 2 $ "Executable stored in: " ++ removeDots moduleName
  when (run opts) $ do
    printVerb opts 1 "Running..."
    let rcmd = "./" ++ removeDots moduleName
    printVerb opts 2 $ "...with command: " ++ rcmd
    system rcmd
    return ()

--- Turns command line arguments into options and arguments.
processOptions :: [String] -> IO (CGOptions, [String])
processOptions argv = do
  let (funopts, args, opterrors) = getOpt Permute options argv
      opts = foldr (\f x -> f x) defaultCGOptions funopts
  unless (null opterrors)
    (putStr (unlines opterrors) >> putStr usageText >> exitWith 1)
  when (help opts) $ do
    putStr $ c2goBanner ++ "\n" ++ usageText
    exitWith 0
  printArgs argv
  when (printName opts || printNumVer opts || printBaseVer opts) (exitWith 0)
  when (not (genMain opts) && run opts) $
    error "Options 'compile' and 'run' cannot be combined!"
  return (opts, args)
 
--- Prints text for certain compiler flags, that need to be
--- printed in the same order as they were provided.
printArgs :: [String] -> IO ()
printArgs []     = return ()
printArgs (x:xs) = case x of
  "--compiler-name"   -> putStrLn lowerCompilerName >> printArgs xs
  "--numeric-version" -> putStrLn packageVersion >> printArgs xs
  "--base-version"    -> printBaseVersion >> printArgs xs
  _                   -> printArgs xs
 where
  printBaseVersion = do
    bvs <- readFile (packagePath </> "lib" </> "VERSION")
    putStrLn (head (lines bvs))

--- Help text
usageText :: String
usageText = usageInfo "Usage: curry2go [options] <input>\n" options

--- Definition of command line options.
options :: [OptDescr (CGOptions -> CGOptions)]
options = 
  [ Option "h?" ["help"]
    (NoArg (\opts -> opts {help = True})) "print help and exit"
  , Option "q" ["quiet"]
           (NoArg (\opts -> opts { verbosity = 0 }))
           "run quietly (no output, only exit code)"
  , Option "v" ["verbosity"]
      (OptArg (maybe (\opts -> opts { verbosity = 2}) checkVerb) "<n>")
         "verbosity level:\n0: quiet (same as `-q')\n1: show status messages (default)\n2: show commands (same as `-v')\n3: show intermedate infos\n4: show all details"
  , Option "" ["dfs"]
    (NoArg (\opts -> opts {strat = DFS})) "use depth first search (default)"
  , Option ""   ["bfs"]
    (NoArg (\opts -> opts {strat = BFS})) "use breadth first search"
  , Option ""   ["fs"]
    (OptArg (maybe (\opts -> opts {strat = FS}) 
    (\s opts -> opts {strat = FS, maxTasks = safeRead s})) "<n>") 
    "use fair search\nn = maximum number of concurrent computations\n(default: 0 = infinite)"
  , Option "c" ["compile"]
           (NoArg (\opts -> opts {genMain = False}))
           "only compile, do not generate executable"
  , Option "r" ["run"]
           (NoArg (\opts -> opts {run = True}))
           "run program after compilation"
  , Option "t" ["time"]
    (OptArg (maybe (\opts -> opts {time = True})
    (\s opts -> opts {time = True, times = safeRead s})) "<n>")
    "print execution time\nn>1: average over runs n"
  , Option "" ["first"]
    (NoArg (\opts -> opts {maxResults = 1}))
    "stop evaluation after the first result"
  , Option "n" ["results"] 
    (ReqArg (\s opts -> opts {maxResults = safeRead s}) "<n>")
    "set maximum number of results to be computed\n(default: 0 = infinite)"
  , Option "i" ["interactive"]
    (NoArg (\opts -> opts {interact = True}))
    "interactive result printing\n(ask to print next result)"
  , Option "s" ["main"]
    (ReqArg (\s opts -> opts {mainName = s}) "<f>")
    "set name of main function to f (default: main)"
  , Option "" ["hnf"]
    (NoArg (\opts -> opts {onlyHnf = True})) "only compute hnf"
  , Option "" ["compiler-name"]
    (NoArg (\opts -> opts {printName = True})) "print the compiler name and exit"
  , Option "" ["numeric-version"]
    (NoArg (\opts -> opts {printNumVer = True})) "print the numeric version and exit"
  , Option "" ["base-version"]
    (NoArg (\opts -> opts {printBaseVer = True})) "print the base version and exit"
  ]
 where
  safeRead s = case reads s of
    [(n,"")] -> n
    _        -> error "Invalid argument! Use -h for help."

  checkVerb s opts = if n >= 0 && n <= 4
                       then opts { verbosity = n }
                       else error "Illegal verbosity level (use `-h' for help)"
   where n = safeRead s

