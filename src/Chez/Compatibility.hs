

module Chez.Compatibility (fixup, intercept) where

import Idris.Core.TT

import IRTS.Lang
import IRTS.Simplified

import Chez.Util

-- This module is where we sweep all the ugly things under the rug.
-- The aim of idris-chez is to be fully compatible with the C backend,
-- but as some functionality in the libraries depend on the C rts or
-- C standard lib functions we have a choice to make: implement those in
-- C or make them in Scheme and patch the call points to point right
-- at compilation time.
-- We will use both approaches. The Prelude.File library should use
-- the Scheme functions for file handling. The CFFI usage of "malloc"
-- and friends should as clearly be left as is.


-- Change the sdecls, this is used when we need
-- to be aware of the context.
fixup :: [(Name, SDecl)] -> [(Name, SDecl)]
fixup decls = map rewriteDecl decls

-- Check a foreign call, and return substitute code if a match
intercept :: FDesc -> FDesc -> [(FDesc, LVar)] -> Maybe String
-- Prelude.Strings
intercept _ (FStr "isNull") [(_, p)] = Just $ predicate (call "idris-chez-isnull" [compileVar p])
intercept _ (FStr "idris_makeStringBuffer") [(_, n)] = Just $ call "idris-chez-stringbuilder" []
intercept _ (FStr "idris_addToString") [(_, p), (_, s)] = Just $ call (compileVar p) [compileVar s]
intercept _ (FStr "idris_getString") [(_, _), (_, p)] = Just $ call (compileVar p) []

-- Prelude.File
intercept _ (FStr "fileOpen") [(_, file), (_, mode)] = 
                            Just $ call "idris-chez-fileopen" [compileVar file, compileVar mode]
intercept _ (FStr "fileSize") [(_, p)] = Just $ call "file-length" [compileVar p]
intercept _ (FStr "idris_showerror") [(_, i)] = Just $ call "idris-chez-showerror" [compileVar i]
intercept _ (FStr "idris_mkFileError") [(_, p)] = Just $ call "idris-chez-makefileerror" []
intercept _ (FStr "fileError") [(_, p)] = Just $ predicate $ call "idris-chez-fileerror" [compileVar p]
intercept _ (FStr "fileClose") [(_, p)] = Just $ call "idris-chez-close-port" [compileVar p]
intercept _ (FStr "idris_fgetc") [(_, p)] = Just $ call "idris-chez-fgetc" [compileVar p]
intercept _ (FStr "idris_fflush") [(_, p)] = Just $ call "flush-output-port" [compileVar p]
intercept _ (FStr "fileEOF") [(_, p)] = Just $ predicate (call "port-eof?" [compileVar p])
-- This doesn't do exactly what fpoll does, but close enough
intercept _ (FStr "fpoll") [(_, p)] = Just $ predicate (call "input-port-ready?" [compileVar p])
intercept _ (FStr "do_popen") [(_, f), (_, m)] = Just $ predicate (call "idris-chez-popen" [compileVar f, compileVar m])
intercept _ (FStr "idris_pclose") [(_, p)] = Just $ call "idris-chez-close-port" [compileVar p]
-- Prelude.Interactive
-- No need to touch getchar and putchar
intercept _ (FStr "idris_disableBuffering") [] = Just $ call "idris-chez-disable-buffering" []
intercept _ (FStr "idris_numArgs") [] = Just $ call "length" [call "command-line" []]
intercept _ (FStr "idris_getArg") [(_, n)] = Just $ call "list-ref" [call "command-line" [], compileVar n]
-- Prelude
-- TODO: Hmmm, collect doesn't like other active threads. Is there a simple fix?
-- For now, let the user beware. 
intercept _ (FStr "idris_forceGC") [_] = Just $ call "collect" []
-- getErrno uses idris_errno: errno is a C macro, what to do? Write a C function...
-- But I want something way more substantial before I go to the bother of including
-- a shared lib.
intercept _ (FStr "idris_errno") [] = Just "0"

-- base
-- System
-- Leave all the standard C functions, just replace idris_time and getEnvPair
intercept _ (FStr "idris_time") [] = Just $ call "time-second" [call "current-time" []]
-- System.Concurrency
--    TODO: Implement
-- Data.Buffer
--    TODO: Implement
-- Data.IORef
intercept _ (FStr "idris_newRef") [(_, r)] = Just $ call "box" [compileVar r] 
intercept _ (FStr "idris_readRef") [(_, r)] = Just $ call "unbox" [compileVar r]
intercept _ (FStr "idris_writeRef") [(_, b), (_, r)] = Just $ call "set-box!" [compileVar b, compileVar r]

-- contrib
-- CFFI: Fine as is
-- Network.Socket
--    TODO: Implement

-- effects
intercept _ (FStr "idris_memset") [(_, p), (_, o), (_, v), (_, s)] = Just $
                     call "idris-chez-memset" [compileVar p, compileVar o, compileVar v, compileVar s]
intercept _ (FStr "idris_memmove") [(_, p), (_, d), (_, op), (_, od),(_, s)] = Just $
                     call "idris-chez-memmove" [compileVar p, compileVar op, compileVar d, compileVar od, compileVar s]
intercept _ (FStr "idris_peek") [(_, o), (_, p)] = Just $
                     call "foreign-ref" ["'unsigned-8", compileVar p, compileVar o]
intercept _ (FStr "idris_poke") [(_, p), (_, o), (_, v)] = Just $
                     call "foreign-set!" ["'unsigned-8", compileVar p, compileVar o, compileVar v]

intercept _ _ _ = Nothing

rewriteDecl :: (Name, SDecl) -> (Name, SDecl)
rewriteDecl (n, sd) | n == sUN "Prelude.File.fgetc" = (n, rewriteFFI "fgetc" "idris_fgetc" sd)
rewriteDecl (n, sd) | n == sUN "Prelude.File.fflush" = (n, rewriteFFI "ffflush" "idris_fflush" sd)
rewriteDecl (n, sd) | n == sUN "Prelude.File.pclose" = (n, rewriteFFI "pclose" "idris_pclose" sd)
rewriteDecl d = d


rewriteFFI :: String -> String -> SDecl -> SDecl
rewriteFFI from to (SFun a b c exp) = SFun a b c (rewriteExp exp)
    where
        rewriteExp (SForeign r (FStr from) a) = SForeign r (FStr to) a
        rewriteExp (SLet v exp body) = SLet v (rewriteExp exp) (rewriteExp body)
        rewriteExp (SCase a b alts) = SCase a b (map rewriteAlt alts)
        rewriteExp (SChkCase a alts) = SChkCase a (map rewriteAlt alts)
        rewriteExp e = e

        rewriteAlt (SConCase a b c d exp) = SConCase a b c d (rewriteExp exp)
        rewriteAlt (SConstCase a exp) = SConstCase a (rewriteExp exp)
        rewriteAlt (SDefaultCase exp) = SDefaultCase (rewriteExp exp)