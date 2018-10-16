module Radicle.Internal.AuthenticatedData where

import           Protolude hiding (hash)

import qualified Data.Map.Strict as Map

import qualified Radicle.Internal.Annotation as Ann
import           Radicle.Internal.Core
import           Radicle.Internal.Hash
import qualified Radicle.Internal.Merkle as Merkle

-- | The location of a datum in a larger datum. Used for constructing proof
-- paths.
data Loc
  -- | 'NthOfVec n i' is the 'i'th element (0-indexed) of a vector of size 'n'.
  = NthOfVec Int Int
  -- | 'HasKeyVal n h' is the element of a dict at key with hash 'h', the dict
  -- having size 'n'.
  | HasKeyVal Int ByteString
  deriving (Generic, Show)

instance FromRad Ann.WithPos Loc
instance ToRad   Ann.WithPos Loc

-- | A verifiable statement about a radicle value.
-- 'Claim path h' says that the the datum at 'path' has hash 'h'.
data Claim = Claim [Loc] ByteString
  deriving (Generic, Show)

instance FromRad Ann.WithPos Claim
instance ToRad   Ann.WithPos Claim

-- | A step in the proof of a 'Claim'.
data ProofElem
  = PfNthOfVec Merkle.Proof
  | PfHasKey Int Merkle.Proof
  deriving (Generic, Show)

instance FromRad Ann.WithPos ProofElem
instance ToRad   Ann.WithPos ProofElem

-- | A proof that a 'Claim' is true.
type Proof = [ProofElem]

hashKeyValue :: ByteString -> ByteString -> ByteString
hashKeyValue k v = Merkle.combi ["key-value", k, v]

-- | A data-structure associated to a radicle value used for constructing proofs
-- of claims about that value. That is, if 'v' is a radicle value and 'hd' is
-- the corresponding 'HashedData', then 'hd' can be used to produce 'Proof's 'p'
-- regarding 'Claim's 'c' about 'v'.
data HashedData
  =
  -- | A simple value
    HashValue ByteString
  -- | A vector of nested values
  | HashVec (Merkle.MerkleTree HashedData)
  -- | A dict of nested values, represented as key-value pairs, with hashed key.
  | HashDict (Merkle.MerkleTree HashedKeyVal)
  deriving (Generic, Show)

instance FromRad Ann.WithPos HashedData
instance ToRad   Ann.WithPos HashedData

-- | A hashed key-value pair of a dict.
data HashedKeyVal = HashedKeyVal ByteString HashedData
  deriving (Generic, Show)

instance FromRad Ann.WithPos HashedKeyVal
instance ToRad   Ann.WithPos HashedKeyVal

instance Merkle.HasHash HashedData where
  hashed = \case
    HashValue h -> hashElem h
    HashVec t -> hashVec (Merkle.hashed t)
    HashDict t -> hashDict (Merkle.hashed t)

hashElem, hashVec, hashDict :: ByteString -> ByteString
hashElem x = Merkle.combi ["elem", x]
hashVec x = Merkle.combi ["vector", x]
hashDict x = Merkle.combi ["dict", x]

instance Merkle.HasHash HashedKeyVal where
  hashed (HashedKeyVal k v) = hashKeyValue k (Merkle.hashed v)

mkProof :: HashedData -> Claim -> Maybe Proof
mkProof (HashValue h) (Claim [] h') =
  if h == h' then Just [] else Nothing
mkProof (HashVec t) (Claim (NthOfVec _ i : locs) h) = do
  (x, pf) <- Merkle.mkProof i t
  rest <- mkProof x (Claim locs h)
  pure (PfNthOfVec pf : rest)
mkProof (HashDict t) (Claim (HasKeyVal _ k : locs) h) = do
    i <- Merkle.getIndex isKey t
    (HashedKeyVal _ x, pf) <- Merkle.mkProof i t
    rest <- mkProof x (Claim locs h)
    pure (PfHasKey i pf : rest)
  where
    isKey (HashedKeyVal k' _) = k == k'
mkProof _ _ = Nothing

zipProof :: Claim -> Proof -> ByteString -> Maybe ByteString
zipProof (Claim [] h) [] el
  | hashElem h == hashElem el = pure $ hashElem el
  | otherwise = Nothing
zipProof (Claim (loc:locs) h) (x:pf) el = case (loc, x) of
  (NthOfVec n i, PfNthOfVec p) -> do
    h' <- zipProof (Claim locs h) pf el
    h'' <- Merkle.zipProof (Merkle.At n i h') p
    pure . hashVec $ h''
  (HasKeyVal n k, PfHasKey i p) -> do
    h' <- zipProof (Claim locs h) pf el
    h'' <- Merkle.zipProof (Merkle.At n i (hashKeyValue k h')) p
    pure . hashDict $ h''
  _ -> Nothing
zipProof _ _ _ = Nothing

checkProof :: Claim -> Proof -> ByteString -> ByteString -> Bool
checkProof claim pf el rootHash =
  zipProof claim pf el == Just rootHash

toHashData :: Value -> Maybe HashedData
toHashData = \case
    Vec xs -> do
      ys <- traverse toHashData (toList xs)
      let t = Merkle.mkMerkleTree ys
      pure $ HashVec t
    Dict m -> do
      let kvs = Map.toList m
      ys <- traverse toHashData (snd <$> kvs)
      let ks = hashRad . fst <$> kvs
      let t = Merkle.mkMerkleTree (zipWith HashedKeyVal ks ys)
      pure $ HashDict t
    v -> Just . HashValue $ hashRad v
