{-# language DeriveAnyClass      #-}
{-# language DeriveDataTypeable  #-}
{-# language FlexibleInstances   #-}
{-# language GADTs               #-}
{-# language Rank2Types          #-}
{-# language StandaloneDeriving  #-}
{-# language TemplateHaskell     #-}
{-# language TypeOperators       #-}

module Pact.Analyze.Types where

import Control.Lens hiding (op, (.>), (...))
import Data.Data
import qualified Data.Decimal as Decimal
import Data.Map.Strict (Map)
import Data.SBV hiding ((.++), Satisfiable, Unsatisfiable, Unknown, ProofError, name)
import qualified Data.SBV.String as SBV
import qualified Data.SBV.Internals as SBVI
import Data.Thyme
import Data.String (IsString(..))
import Pact.Types.Lang hiding (Term, TableName, Type, TObject, EObject, KeySet,
                               TKeySet)

import Pact.Analyze.Prop

data Provenance
  = Provenance
    { _provTableName  :: TableName
    , _provColumnName :: S ColumnName
    , _provRowKey     :: S RowKey
    , _provDirty      :: S Bool
    }
  deriving (Eq, Show)

-- Symbolic value carrying provenance, for tracking if values have come from a
-- particular table+row.
data S a
  = S
    { _sProv :: Maybe Provenance
    , _sSbv  :: SBV a }
  deriving (Eq, Show)

instance SymWord a => Mergeable (S a) where
  symbolicMerge f t (S prov1 x) (S prov2 y)
    | prov1 == prov2 = S prov1   (symbolicMerge f t x y)
    | otherwise      = S Nothing (symbolicMerge f t x y)

-- We provide instances for EqSymbolic, OrdSymboic, Boolean because we need
-- these operators for `S a` now that we work with that instead of `SBV a`
-- everywhere:

instance EqSymbolic (S a) where
  (S _ x) .== (S _ y) = x .== y

instance SymWord a => OrdSymbolic (S a) where
  S _ x .< S _ y = x .< y

-- We don't care about preserving the provenance value here as we are most
-- interested in tracking `SBV KeySet`s, but really as soon as we apply a
-- transformation to a symbolic value, we are no longer working with the value
-- that was sourced from the database.
instance Boolean (S Bool) where
  true            = S Nothing true
  false           = S Nothing false
  bnot (S _ x)    = S Nothing (bnot x)
  S _ x &&& S _ y = S Nothing (x &&& y)
  S _ x ||| S _ y = S Nothing (x ||| y)

instance IsString (S String) where
  fromString = sansProv . fromString

instance (Num a, SymWord a) => Num (S a) where
  S _ x + S _ y  = S Nothing (x + y)
  S _ x * S _ y  = S Nothing (x * y)
  abs (S _ x)    = S Nothing (abs x)
  signum (S _ x) = S Nothing (signum x)
  fromInteger i  = S Nothing (fromInteger i)
  negate (S _ x) = S Nothing (negate x)

instance (Fractional a, SymWord a) => Fractional (S a) where
  fromRational = literalS . fromRational
  S _ x / S _ y = S Nothing (x / y)

instance SDivisible (S Integer) where
  S _ a `sQuotRem` S _ b = a `sQuotRem` b & both %~ S Nothing
  S _ a `sDivMod`  S _ b = a `sDivMod`  b & both %~ S Nothing

type PredicateS = Symbolic (S Bool)

instance Provable PredicateS where
  forAll_   = fmap _sSbv
  forAll _  = fmap _sSbv
  forSome_  = fmap _sSbv
  forSome _ = fmap _sSbv

-- Until SBV adds a typeclass for strConcat/(.++):
(.++) :: S String -> S String -> S String
S _ a .++ S _ b = S Nothing (SBV.concat a b)

-- Beware: not a law-abiding Iso. Drops provenance info.
sbv2S :: Iso (SBV a) (SBV b) (S a) (S b)
sbv2S = iso sansProv _sSbv

sbv2SFrom :: Provenance -> Iso (SBV a) (SBV b) (S a) (S b)
sbv2SFrom prov = iso (withProv prov) _sSbv

s2Sbv :: Iso (S a) (S b) (SBV a) (SBV b)
s2Sbv = from sbv2S

mkProv :: TableName -> S ColumnName -> S RowKey -> S Bool -> Provenance
mkProv tn sCn sRk sDirty = Provenance tn sCn sRk sDirty

symRowKey :: S String -> S RowKey
symRowKey = coerceS

data Object
  = Object (Map String (EType, AVal))
  deriving (Eq, Show)

newtype Schema
  = Schema (Map String EType)
  deriving (Show, Eq)

-- | Untyped symbolic value.
data AVal
  = AVal (Maybe Provenance) SBVI.SVal
  | AnObj Object
  | OpaqueVal
  deriving (Eq, Show)

mkS :: Maybe Provenance -> SBVI.SVal -> S a
mkS mProv sval = S mProv (SBVI.SBV sval)

sansProv :: SBV a -> S a
sansProv = S Nothing

literalS :: SymWord a => a -> S a
literalS a = sansProv $ literal a

unliteralS :: SymWord a => S a -> Maybe a
unliteralS = unliteral . _sSbv

withProv :: Provenance -> SBV a -> S a
withProv prov sym = S (Just prov) sym

mkAVal :: S a -> AVal
mkAVal (S mProv (SBVI.SBV sval)) = AVal mProv sval

mkAVal' :: SBV a -> AVal
mkAVal' (SBVI.SBV sval) = AVal Nothing sval

coerceSBV :: SBV a -> SBV b
coerceSBV = SBVI.SBV . SBVI.unSBV

coerceS :: S a -> S b
coerceS (S mProv a) = S mProv $ coerceSBV a

iteS :: Mergeable a => S Bool -> a -> a -> a
iteS sbool = ite (_sSbv sbool)

liftSbv :: (SBV a -> SBV b) -> S a -> S b
liftSbv f = sansProv . f . _sSbv

fromIntegralS
  :: forall a b
  . (Integral a, HasKind a, Num a, SymWord a, HasKind b, Num b, SymWord b)
  => S a
  -> S b
fromIntegralS = liftSbv sFromIntegral

realToIntegerS :: S AlgReal -> S Integer
realToIntegerS = liftSbv sRealToSInteger

oneIfS :: (Num a, SymWord a) => S Bool -> S a
oneIfS = liftSbv oneIf

isConcreteS :: SymWord a => S a -> Bool
isConcreteS = isConcrete . _sSbv

data UserType = UserType
  deriving (Eq, Ord, Read, Data, Show)

deriving instance HasKind UserType
deriving instance SymWord UserType

-- KeySets are completely opaque to pact programs -- 256 should be enough for
-- symbolic analysis?
newtype KeySet
  = KeySet Word8
  deriving (Eq, Ord, Data, Show, Read)

-- "Giving no instances is ok when defining an uninterpreted/enumerated sort"
instance SymWord KeySet
instance HasKind KeySet where kindOf (KeySet rep) = kindOf rep

-- Operations that apply to a pair of either integer or decimal, resulting in
-- the same:
-- integer -> integer -> integer
-- decimal -> decimal -> decimal
--
-- Or:
-- integer -> decimal -> integer
-- decimal -> integer -> integer
data ArithOp
  = Add
  | Sub
  | Mul
  | Div
  | Pow
  | Log
  deriving (Show, Eq)

-- integer -> integer
-- decimal -> decimal
data UnaryArithOp
  = Negate
  | Sqrt
  | Ln
  | Exp
  | Abs

  -- Implemented only for the sake of the Num instance
  | Signum
  deriving (Show, Eq)

-- decimal -> integer -> decimal
-- decimal -> decimal
data RoundingLikeOp
  = Round
  | Ceiling
  | Floor
  deriving (Show, Eq)

data ComparisonOp = Gt | Lt | Gte | Lte | Eq | Neq
  deriving (Show, Eq)

data Any = Any
  deriving (Show, Read, Eq, Ord, Data)

instance HasKind Any
instance SymWord Any

-- The type of a simple type
data Type a where
  TInt     :: Type Integer
  TBool    :: Type Bool
  TStr     :: Type String
  TTime    :: Type Time
  TDecimal :: Type Decimal
  TKeySet  :: Type KeySet
  TAny     :: Type Any

data EType where
  -- TODO: parametrize over constraint
  EType :: (Show a, SymWord a) => Type a -> EType
  EObjectTy :: Schema -> EType

typeEq :: Type a -> Type b -> Maybe (a :~: b)
typeEq TInt     TInt     = Just Refl
typeEq TBool    TBool    = Just Refl
typeEq TStr     TStr     = Just Refl
typeEq TTime    TTime    = Just Refl
typeEq TDecimal TDecimal = Just Refl
typeEq TAny     TAny     = Just Refl
typeEq TKeySet  TKeySet  = Just Refl
typeEq _        _        = Nothing

instance Eq EType where
  EType a == EType b = case typeEq a b of
    Just _refl -> True
    Nothing    -> False
  EObjectTy a == EObjectTy b = a == b
  _ == _ = False

data ETerm where
  -- TODO: remove Show (add constraint c?)
  ETerm   :: (Show a, SymWord a) => Term a      -> Type a -> ETerm
  EObject ::                        Term Object -> Schema -> ETerm

mapETerm :: (forall a. Term a -> Term a) -> ETerm -> ETerm
mapETerm f term = case term of
  ETerm term' ty    -> ETerm (f term') ty
  EObject term' sch -> EObject (f term') sch

data Term ret where
  IfThenElse     ::                        Term Bool    -> Term a         -> Term a -> Term a
  Enforce        ::                        Term Bool    ->                             Term Bool
  -- TODO: do we need a noop to handle a sequence of one expression?
  Sequence       ::                        ETerm        -> Term a         ->           Term a
  Literal        ::                        S a          ->                             Term a

  --
  -- TODO: we need to allow computed keys here
  --
  LiteralObject  ::                        Map String (EType, ETerm)      ->           Term Object

  -- At holds the schema of the object it's accessing. We do this so we can
  -- determine statically which fields can be accessed.
  At             ::                        Schema      -> Term String              -> Term Object    -> EType -> Term a
  Read           ::                        TableName   -> Schema -> Term String    ->                   Term Object
  ReadCols       ::                        TableName   -> Schema -> Term String    -> [Text]         -> Term Object
  -- NOTE: pact really does return a string here:
  Write          ::                        TableName -> Term String -> Term Object -> Term String

  Let            ::                        Text         -> ETerm         -> Term a  -> Term a
  -- TODO: not sure if we need a separate `Bind` ctor for object binding. try
  --       just using Let+At first.
  Var            ::                        Text         ->                             Term a

  -- We partition the arithmetic operations in to these classes:
  -- * DecArithOp, IntArithOp: binary operators applied to (and returning) the
  --   same type (either integer or decimal).
  --   - Operations: { + - * / ^ log }
  -- * DecUnaryArithOp, IntUnaryArithOp: unary operators applied to and
  --   returning the same type (integer or decimal).
  --   - Operations: { - (negate) sqrt ln exp abs } (also signum even though
  --     it's not in pact)
  -- * DecIntArithOp, IntDecArithOp: binary operators applied to one integer
  --   and one decimal, returning a decimal. These are overloads of the integer
  --   / decimal binary ops.
  --   - Operations: { + - * / ^ log }
  -- * ModOp: Just modulus (oddly, it's the only operator with signature
  --   `integer -> integer -> integer`.
  --   - Operations: { mod }
  --
  -- * RoundingLikeOp1: Rounding decimals to integers.
  --   - Operations: { round floor ceiling }
  -- * RoundingLikeOp2: Rounding decimals to decimals with a specified level of
  --   precision.
  --   - Operations: { round floor ceiling }
  --
  -- * AddTime: Arguably not an arithmetic op, but under the hood it's just
  --   adding some number of (micro)seconds.

  DecArithOp      :: ArithOp      -> Term Decimal -> Term Decimal -> Term Decimal
  IntArithOp      :: ArithOp      -> Term Integer -> Term Integer -> Term Integer
  DecUnaryArithOp :: UnaryArithOp                 -> Term Decimal -> Term Decimal
  IntUnaryArithOp :: UnaryArithOp                 -> Term Integer -> Term Integer

  DecIntArithOp   :: ArithOp -> Term Decimal -> Term Integer -> Term Decimal
  IntDecArithOp   :: ArithOp -> Term Integer -> Term Decimal -> Term Decimal

  ModOp           :: Term Integer   -> Term Integer -> Term Integer
  RoundingLikeOp1 :: RoundingLikeOp -> Term Decimal -> Term Integer
  RoundingLikeOp2 :: RoundingLikeOp -> Term Decimal -> Term Integer -> Term Decimal

  -- invariant (inaccessible): a ~ Integer or a ~ Decimal
  AddTime         :: Term Time -> ETerm -> Term Time

  Comparison     :: (Show a, SymWord a) => ComparisonOp -> Term a         -> Term a -> Term Bool
  Logical        ::                        LogicalOp    -> [Term Bool]    ->           Term Bool
  ReadKeySet     ::                        Term String  ->                             Term KeySet
  KsAuthorized   ::                        Term KeySet  ->                             Term Bool
  NameAuthorized ::                        Term String  ->                             Term Bool
  Concat         ::                        Term String  -> Term String    ->           Term String
  PactVersion    ::                                                                    Term String

deriving instance Show a => Show (Term a)
deriving instance Show ETerm

deriving instance Show (Type a)
deriving instance Eq (Type a)
deriving instance Show EType

lit :: SymWord a => a -> Term a
lit = Literal . literalS

instance Num (Term Integer) where
  fromInteger = Literal . fromInteger
  (+)    = IntArithOp Add
  (*)    = IntArithOp Mul
  abs    = IntUnaryArithOp Abs
  signum = IntUnaryArithOp Signum
  negate = IntUnaryArithOp Negate

instance Num (Term Decimal) where
  fromInteger = lit . mkDecimal . fromInteger
  (+)    = DecArithOp Add
  (*)    = DecArithOp Mul
  abs    = DecUnaryArithOp Abs
  signum = DecUnaryArithOp Signum
  negate = DecUnaryArithOp Negate

type Time = Int64
type STime = SBV Time

mkTime :: UTCTime -> Time
mkTime utct
  = ((utct ^. _utctDay . to toModifiedJulianDay . to fromIntegral)
    * (1000000 * 60 * 60 * 24))
  + (utct ^. _utctDayTime . microseconds)

-- Pact uses Data.Decimal which is arbitrary-precision
type Decimal = AlgReal
type SDecimal = SBV Decimal

mkDecimal :: Decimal.Decimal -> Decimal
mkDecimal (Decimal.Decimal places mantissa) = fromRational $
  mantissa % 10 ^ places

makeLenses ''S
makeLenses ''Object
