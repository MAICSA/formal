
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}


module Formal.TypeCheck where

import List (nub, (\\), intersect, union, partition)
import Monad (msum)

import qualified Data.Map as M
import qualified Data.List as L

import Data.Monoid

import Formal.Types.Literal
import Formal.Types.Pattern
import Formal.Types.Symbol
import Formal.Types.Expression
import Formal.Types.Definition
import Formal.Types.Axiom
import Formal.Types.Statement hiding (find)
import Formal.Parser

type Id = String

enumId :: Int -> Id
enumId n = "v" ++ show n

data Kind = Star | KindFunction Kind Kind deriving (Show, Eq)


type Key = String

data Type = TypeVar TypeVar
          | Type TypeConst
          | TypeApplication Type Type
          | TypeRecord TypeRecord
          | TypeGen Int -- (?)
            deriving Eq

instance Show Type where
    show (TypeVar (TVar i _)) = i
    show (Type (TypeConst i _)) = i
    show (TypeApplication (Type (TypeConst "->" _)) u) = show u ++ " ->"
    show (TypeApplication t u) = "(" ++ show t ++ " " ++ show u ++ ")"
    show (TypeGen x) = "v" ++ show x



data TypeRecord = TRecord (M.Map Key Type) Kind
                deriving (Show, Eq)

data TypeVar = TVar Id Kind
               deriving (Show, Eq)

data TypeConst = TypeConst Id Kind -- (?)
                 deriving (Show, Eq)


-- These are primitive type constants (MPJ pg.6)

unit_type = TypeRecord (TRecord mempty Star)
char_type = Type (TypeConst "Char" Star)
num_type  = Type (TypeConst "Num" Star)
fun_type  = Type (TypeConst "->"  (KindFunction Star (KindFunction Star Star)))

array_type  = Type (TypeConst "Array" (KindFunction Star Star))
string_type = TypeApplication array_type char_type


infixr 4 -:>
(-:>) :: Type -> Type -> Type
a -:> b = TypeApplication (TypeApplication fun_type a) b

class HasKind t where kind :: t -> Kind

instance HasKind TypeVar where   kind (TVar _ k) = k
instance HasKind TypeConst where kind (TypeConst _ k) = k
instance HasKind TypeRecord where kind (TRecord _ k) = k
instance HasKind Type where
    kind (Type x) = kind x
    kind (TypeVar x) = kind x
    kind (TypeRecord x) = kind x
    kind (TypeApplication (kind -> KindFunction _ k)  _) = k

type Substitution = [(TypeVar, Type)]

(+->) :: TypeVar -> Type -> Substitution
x +-> y = [(x, y)]

class Types t where
    apply :: Substitution -> t -> t
    tv :: t -> [TypeVar]

instance Types Type where
    apply s (TypeVar u) = case lookup u s of 
                            Just x -> x
                            Nothing -> TypeVar u
    apply s (TypeApplication l r) = TypeApplication (apply s l) (apply s r)
    apply s (TypeRecord (TRecord xs k)) = TypeRecord (TRecord (fmap (apply s) xs) k)
    apply _ t = t

    tv (TypeVar u) = [u]
    tv (TypeApplication l r) = tv l `union` tv r
    tv (TypeRecord (TRecord xs _)) = nub $ M.elems xs >>= tv
    tv t = []

instance Types a => Types [a] where
    apply s = map (apply s)
    tv = nub . concat . map tv

infixr 4 @@
(@@) :: Substitution -> Substitution -> Substitution
s1 @@ s2 = ([(u, apply s1 t) | (u, t) <- s2] ++ s1)

merge :: Monad m => Substitution -> Substitution -> m Substitution
merge s1 s2 = if agree then return (s1 ++ s2) else fail "merge fails"
    where agree = all f (map fst s1 `intersect` map fst s2)
          f (TypeVar -> v) = apply s1 v == apply s2 v



-- Unification
-- --------------------------------------------------------------------------------

mgu      :: Monad m => Type -> Type -> m Substitution
var_bind :: Monad m => TypeVar -> Type -> m Substitution
match    :: Monad m => Type -> Type -> m Substitution


mgu (TypeApplication l1 r1) (TypeApplication l2 r2) =
    do s1 <- mgu l1 l2
       s2 <- mgu r1 r2
       return (s1 @@ s2)

mgu t (TypeVar u)  = var_bind u t
mgu (TypeVar u) t  = var_bind u t
mgu (TypeRecord t) (TypeRecord u) 
    | t == u       = return [] -- (?)  is this how records should be unified?
mgu (Type t) (Type u)
    | t == u       = return []
mgu t u            = fail "Types do not unify"

var_bind u t | t == TypeVar u   = return []
             | u `elem` tv t    = fail "occurs check fails"
             | kind u /= kind t = fail "kinds do not match"
             | otherwise        = return (u +-> t)

match (TypeApplication l1 r1) (TypeApplication l2 r2) =
    do s1 <- match l1 l2
       s2 <- match r1 r2
       merge s1 s2

match (TypeVar u) t 
    | kind u == kind t = return (u +-> t)
match (TypeRecord t) (TypeRecord u) 
    | t == u           = return [] -- (?)  is this how records should be matched?
match (Type t) (Type u)
    | t == u           = return []
match t u              = fail "Types do not match"



-- Type Classes
-- --------------------------------------------------------------------------------

data Qual t = [Pred] :=> t deriving Eq
data Pred = IsIn Id Type deriving (Show, Eq)

instance (Show t) => Show (Qual t) where
    show (_ :=> t) = show t

instance Types t => Types (Qual t) where
  apply s (ps :=> t) = apply s ps :=> apply s t
  tv (ps :=> t)      = tv ps `union` tv t

instance Types Pred where
  apply s (IsIn i t) = IsIn i (apply s t)
  tv (IsIn i t)      = tv t

mguPred, matchPred :: Pred -> Pred -> Maybe Substitution
mguPred             = lift mgu
matchPred           = lift match

lift m (IsIn i t) (IsIn i' t')
         | i == i'   = m t t'
         | otherwise = fail "classes differ"

type Class    = ([Id], [Inst])
type Inst     = Qual Pred



-- Class Environments
-- --------------------------------------------------------------------------------

data ClassEnv = ClassEnv { classes  :: Id -> Maybe Class,
                           defaults :: [Type] }

super     :: ClassEnv -> Id -> [Id]
super ce i = case classes ce i of Just (is, its) -> is

insts     :: ClassEnv -> Id -> [Inst]
insts ce i = case classes ce i of Just (is, its) -> its

defined :: Maybe a -> Bool
defined (Just x) = True
defined Nothing  = False

modify :: ClassEnv -> Id -> Class -> ClassEnv
modify ce i c = ce{classes = \j -> if i==j then Just c
                                           else classes ce j}

initialEnv :: ClassEnv
initialEnv  = ClassEnv { classes  = \_ -> fail "class not defined",
                         defaults = [num_type] }

type EnvTransformer = ClassEnv -> Maybe ClassEnv

infixr 5 <:>
(<:>)       :: EnvTransformer -> EnvTransformer -> EnvTransformer
(f <:> g) ce = do ce' <- f ce
                  g ce'

addClass                              :: Id -> [Id] -> EnvTransformer
addClass i is ce
 | defined (classes ce i)              = fail "class already defined"
 | any (not . defined . classes ce) is = fail "superclass not defined"
 | otherwise                           = return (modify ce i (is, []))

addPreludeClasses :: EnvTransformer
addPreludeClasses  = addCoreClasses <:> addNumClasses

addCoreClasses ::   EnvTransformer
addCoreClasses  =   addClass "Eq" []
                <:> addClass "Ord" ["Eq"]
                <:> addClass "Show" []
                <:> addClass "Read" []
                <:> addClass "Bounded" []
                <:> addClass "Enum" []
                <:> addClass "Functor" []
                <:> addClass "Monad" []

addNumClasses  ::   EnvTransformer
addNumClasses   =   addClass "Num" ["Eq", "Show"]
                <:> addClass "Real" ["Num", "Ord"]
                <:> addClass "Fractional" ["Num"]
                <:> addClass "Integral" ["Real", "Enum"]
                <:> addClass "RealFrac" ["Real", "Fractional"]
                <:> addClass "Floating" ["Fractional"]
                <:> addClass "RealFloat" ["RealFrac", "Floating"]



-- Entailment
-- --------------------------------------------------------------------------------

bySuper :: ClassEnv -> Pred -> [Pred]
bySuper ce p@(IsIn i t) =
    p : concat [ bySuper ce (IsIn i' t) | i' <- super ce i ]

byInst :: ClassEnv -> Pred -> Maybe [Pred]
byInst ce p@(IsIn i t)    = msum [ tryInst it | it <- insts ce i ]
 where tryInst (ps :=> h) = do u <- matchPred h p
                               Just (map (apply u) ps)

entail        :: ClassEnv -> [Pred] -> Pred -> Bool
entail ce ps p = any (p `elem`) (map (bySuper ce) ps) ||
                 case byInst ce p of
                   Nothing -> False
                   Just qs -> all (entail ce ps) qs

inHnf       :: Pred -> Bool
inHnf (IsIn c t) = hnf t
   where hnf (TypeVar v)  = True
         hnf (Type tc) = False
         hnf (TypeApplication t _) = hnf t

toHnfs      :: Monad m => ClassEnv -> [Pred] -> m [Pred]
toHnfs ce ps = do pss <- mapM (toHnf ce) ps
                  return (concat pss)

toHnf                 :: Monad m => ClassEnv -> Pred -> m [Pred]
toHnf ce p | inHnf p   = return [p]
           | otherwise = case byInst ce p of
                           Nothing -> fail "context reduction"
                           Just ps -> toHnfs ce ps

simplify   :: ClassEnv -> [Pred] -> [Pred]
simplify ce = loop []
 where loop rs []                            = rs
       loop rs (p:ps) | entail ce (rs++ps) p = loop rs ps
                      | otherwise            = loop (p:rs) ps

reduce      :: Monad m => ClassEnv -> [Pred] -> m [Pred]
reduce ce ps = do qs <- toHnfs ce ps
                  return (simplify ce qs)

scEntail        :: ClassEnv -> [Pred] -> Pred -> Bool
scEntail ce ps p = any (p `elem`) (map (bySuper ce) ps)



-- Type Schemes
-- --------------------------------------------------------------------------------

data Scheme = Forall [Kind] (Qual Type) deriving Eq

instance Show Scheme where
    show (Forall [] t) = show t
    show (Forall xs t) = "forall " ++ vars ++ " => " ++ show t
        where vars = concat . L.intersperse " " . map (\x -> "_" ++ show x) . take (length xs) $ [0..]

instance Types Scheme where
  apply s (Forall ks qt) = Forall ks (apply s qt)
  tv (Forall _ qt)      = tv qt

quantify      :: [TypeVar] -> Qual Type -> Scheme
quantify vs qt = Forall ks (apply s qt)
 where vs' = [ v | v <- tv qt, v `elem` vs ]
       ks  = map kind vs'
       s   = zip vs' (map TypeGen [0..])

toScheme      :: Type -> Scheme
toScheme t     = Forall [] ([] :=> t)



-- Assumptions
-- --------------------------------------------------------------------------------

data Assumption = Id :>: Scheme

newtype A = A [Assumption]

instance Show A where
    show (A []) = ""
    show (A (i :>: s : xs)) = i ++ ": " ++ show s ++ "\n" ++ show (A xs)

instance Types Assumption where
    apply s (i :>: sc) = i :>: (apply s sc)
    tv (i :>: sc)      = tv sc

find :: Monad m => Id -> [Assumption] -> m Scheme
find i []             = fail ("unbound identifier: " ++ i)
find i ((i':>:sc):as) = if i==i' then return sc else find i as



-- Type Inference Monad
-- --------------------------------------------------------------------------------

newtype TI a = TI (Substitution -> Int -> ClassEnv -> (Substitution, Int, ClassEnv, a))

instance Monad TI where
  return x   = TI (\s n ce -> (s, n, ce, x))
  TI f >>= g = TI (\s n ce -> case f s n ce of
                                (s',m,ce, x) -> let TI gx = g x
                                               in  gx s' m ce)

runTI :: TI a -> a
runTI (TI f) = x where (s,n,ce,x) = f [] 0 initialEnv

get_substitution :: TI Substitution
get_substitution   = TI (\s n ce -> (s,n,ce,s))

get_classenv :: TI ClassEnv
get_classenv = TI (\s n ce -> (s,n,ce,ce))

unify      :: Type -> Type -> TI ()
unify t1 t2 = do s <- get_substitution
                 u <- mgu (apply s t1) (apply s t2)
                 extSubst u

    where extSubst   :: Substitution -> TI ()
          extSubst s' = TI (\s n ce -> (s'@@s, n, ce, ()))

newTVar :: Kind -> TI Type
newTVar k   = TI (\s n ce -> let v = TVar (enumId n) k
                             in  (s, n+1, ce, TypeVar v))

freshInst :: Scheme -> TI (Qual Type)
freshInst (Forall ks qt) = do ts <- mapM newTVar ks
                              return (inst ts qt)

class Instantiate t where
  inst  :: [Type] -> t -> t

instance Instantiate Type where
  inst ts (TypeApplication l r) = TypeApplication (inst ts l) (inst ts r)
  inst ts (TypeGen n)  = ts !! n
  inst ts t            = t

instance Instantiate a => Instantiate [a] where
  inst ts = map (inst ts)

instance Instantiate t => Instantiate (Qual t) where
  inst ts (ps :=> t) = inst ts ps :=> inst ts t

instance Instantiate Pred where
  inst ts (IsIn c t) = IsIn c (inst ts t)



-- Type Inference
-- --------------------------------------------------------------------------------

-- Literals

tiLit :: Literal -> TI ([Pred],Type)
tiLit (StringLiteral _) = return ([], Type (TypeConst "String" Star))
tiLit (IntLiteral _)    = return ([], Type (TypeConst "Num" Star))
tiLit (IntLiteral _)    = return ([], Type (TypeConst "Num" Star))

-- Patterns

tiPat :: forall b. Pattern b -> TI ([Pred], [Assumption], Type)
tiPat (VarPattern i) = do v <- newTVar Star
                          return ([], [i :>: toScheme v], v)

tiPat AnyPattern = do v <- newTVar Star
                      return ([], [], v)

tiPat (LiteralPattern x) = do (ps, t) <- tiLit x
                              return (ps, [], t)

tiPat (ListPattern xs) = do (ps, as, ts) <- tiPats xs
                            t'           <- newTVar Star
                            (qs :=> t)   <- freshInst list_scheme
                            mapM_ (unify t') ts
                            return (ps ++ qs, as, t)

tiPat (RecordPattern (unzip . M.toList -> (names, patterns))) =
    
    do (ps, as, ts) <- tiPats patterns
       t'           <- newTVar Star
       unify t' (TypeRecord (TRecord (M.fromList (zip (map f names) ts)) Star))
       return (ps, as, t')

    where f (Symbol x) = x
          f (Operator x) = x

list_scheme :: Scheme
list_scheme = Forall [Star] qual_list
    where qual_list = [] :=> TypeApplication (Type (TypeConst "List" (KindFunction Star Star))) (TypeGen 0)

tiPats     :: forall b. [Pattern b] -> TI ([Pred], [Assumption], [Type])
tiPats pats = do psasts <- mapM tiPat pats
                 let ps = concat [ ps' | (ps',_,_) <- psasts ]
                     as = concat [ as' | (_,as',_) <- psasts ]
                     ts = [ t | (_,_,t) <- psasts ]
                 return (ps, as, ts)

-- Matches

bool_type :: Type
bool_type = undefined

tiMatch :: [Assumption] -> (Match (Expression Definition)) -> TI ([Pred], [Assumption], [Type])
tiMatch as (Match x Nothing) = do (ps, as', xe) <- tiPats x
                                  return (ps, as', xe)

tiMatch as (Match x (Just y)) = do (ps, as', xe) <- tiPats x
                                   (ps', t) <- tiExpr (as' ++ as) y
                                   unify bool_type t
                                   return (ps ++ ps', as', xe)

-- Expressions


type Infer e t = [Assumption] -> e -> TI ([Pred], t)

-- class Infer e where
--     infer :: ClassEnv -> [Assumption] -> e -> TI ([Pred], [Assumption], Type)

infixr      4 `fn`
fn         :: Type -> Type -> Type
a `fn` b    = TypeApplication (TypeApplication fun_type a) b
 

tiExpr :: Infer (Expression b) Type
tiExpr as (SymbolExpression i) = do sc <- find (show i) as
                                    (ps :=> t) <- freshInst sc
                                    return (ps, t)

tiExpr as (LiteralExpression s) = do (ps, t) <- tiLit s
                                     return (ps, t)

tiExpr as (JSExpression s) = do t <- newTVar Star
                                return ([], t)
       


tiExpr as (ApplyExpression e []) = fail "This should not be"
tiExpr as (ApplyExpression e (x:[])) = do (ps, te) <- tiExpr as e
                                          (qs, tx) <- tiExpr as x
                                          t        <- newTVar Star
                                          unify (tx `fn` t) te
                                          return (ps ++ qs, t)

tiExpr as (ApplyExpression e (x:xs)) = tiExpr as (ApplyExpression (ApplyExpression e (x:[])) xs)

tiExpr as (RecordExpression (unzip . M.toList -> (names, xs))) =

    do (ps, ts) <- tiExprs as xs
       t <- newTVar Star
       unify t (TypeRecord (TRecord (M.fromList (zip (map f names) ts)) Star))
       return (ps, t)

    where f (Symbol x) = x
          f (Operator x) = x

tiExprs :: forall b. Infer [Expression b] [Type]
tiExprs as xs = do exprs <- mapM (tiExpr as) xs
                   let ps = concat [ ps' | (ps',_) <- exprs ]
                       ts = [ t | (_,t) <- exprs ]
                   return (ps, ts)

-- Axioms

tiAxiom :: Infer (Axiom (Expression Definition)) Type
tiAxiom as (EqualityAxiom m x) = do (ps, as', ts) <- tiMatch as m
                                    (qs, t)       <- tiExpr (as' ++ as) x
                                    return (ps ++ qs, foldr fn t ts)

tiAxioms :: [Assumption] -> [Axiom (Expression Definition)] -> Type -> TI [Pred]
tiAxioms as axs t = do ps <- mapM (tiAxiom as) axs
                       mapM (unify t) (map snd ps)
                       return (concat (map fst ps))

-- Generalization

split :: Monad m => ClassEnv -> [TypeVar] -> [TypeVar] -> [Pred] -> m ([Pred], [Pred])
split ce fs gs ps = do ps' <- reduce ce ps
                       let (ds, rs) = partition (all (`elem` fs) . tv) ps'
                     --  rs' <- defaultedPreds ce (fs++gs) rs
                       return (ds, rs) -- \\ rs')

-- Ambiguity

-- type Ambiguity       = (TypeVar, [Pred])

-- ambiguities :: ClassEnv -> [TypeVar] -> [Pred] -> [Ambiguity]
-- ambiguities ce vs ps = [ (v, filter (elem v . tv) ps) | v <- tv ps \\ vs ]

-- defaultedPreds = undefined

-- Definitions

restricted :: [Definition] -> Bool
restricted bs = any simple bs
    where simple (Definition i axs) = any (null . f) axs
          f (EqualityAxiom (Match p _) _) = p
          f _ = error "Not Defined"

tiImpls :: Infer [Definition] [Assumption]
tiImpls as bs = do ts <- mapM (\_ -> newTVar Star) bs
                   let is    = map get_name bs
                       scs   = map toScheme ts
                       as'   = zipWith (:>:) is scs ++ as
                       altss = map get_axioms bs
                   pss <- sequence (zipWith (tiAxioms as') altss ts)
                   s   <- get_substitution
                   let ps' = apply s (concat pss)
                       ts' = apply s ts
                       fs  = tv (apply s as)
                       vss = map tv ts'
                       gs  = foldr1 union vss \\ fs
                   ce <- get_classenv
                   (ds,rs) <- split ce fs (foldr1 intersect vss) ps'
                   if restricted bs then
                       let gs'  = gs \\ tv rs
                           scs' = map (quantify gs' . ([]:=>)) ts'
                       in return (ds++rs, zipWith (:>:) is scs')
                     else
                       let scs' = map (quantify gs . (rs:=>)) ts'
                       in return (ds, zipWith (:>:) is scs')

    where get_name (Definition (Symbol x) _) = x
          get_name (Definition (Operator x) _) = x
          get_axioms (Definition _ x) = x

type BindGroup  = ([Definition], [[Definition]])

tiBindGroup :: Infer BindGroup [Assumption]
tiBindGroup as (es,iss) =
  do (ps, as'') <- tiSeq tiImpls (as) iss
     qss        <- return []
     return (ps++concat qss, as'')

tiSeq :: Infer bg [Assumption] -> Infer [bg] [Assumption]
tiSeq ti as []       = return ([],[])
tiSeq ti as (bs:bss) = do (ps,as')  <- ti as bs
                          (qs,as'') <- tiSeq ti (as'++as) bss
                          return (ps++qs, as''++as')

tiProgram :: [Assumption] -> Program -> [Assumption]
tiProgram as bgs = runTI $
                      do let bg = to_group bgs
                         (ps, as') <- tiSeq tiBindGroup as [([], (map (:[]) bg))]
                         s         <- get_substitution
                         ce        <- get_classenv
                         rs        <- reduce ce (apply s ps)
                         return (apply (s) as')

    where to_group (Program xs) = [ y | x <- xs, y <- g x ]
          g (DefinitionStatement a) = [a]
          g _ = []
