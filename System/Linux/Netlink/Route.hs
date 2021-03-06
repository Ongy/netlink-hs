{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}

{-|
Module      : System.Linux.Netlink.Route
Description : The implementation for netlinks route family
Maintainer  : ongy
Stability   : testing
Portability : Linux

This module provides wrappers for functionality provided by the netlink route family
-}
module System.Linux.Netlink.Route
    (
      Packet
    , RoutePacket

    , getRoutePackets
    , Message(..)
    
    , getLinkAddress
    , getLinkBroadcast
    , getLinkName
    , getLinkMTU
    , getLinkQDisc
    , getLinkTXQLen
    , getIFAddr
    , getLLAddr
    , getDstAddr

    , putLinkAddress
    , putLinkBroadcast
    , putLinkName
    , putLinkMTU
    , putLinkQDisc
    , putLinkTXQLen
    ) where

import Prelude hiding (length, lookup, init)

#if MIN_VERSION_base(4,8,0)
#else
import Control.Applicative ((<$>), (<*>))
#endif

import qualified Data.ByteString as BS (length)
import Data.ByteString.Char8 (ByteString, append, init, pack, unpack)
import Data.Char (chr, ord)
import Data.List (intersperse)
import Data.Map (insert, lookup, toList)
import Data.Serialize.Get
import Data.Serialize.Put
import Data.Word (Word8, Word16, Word32)
import Data.Int (Int32)

import System.Linux.Netlink.Constants
import System.Linux.Netlink
import System.Linux.Netlink.Helpers
import System.Linux.Netlink.Route.LinkStat

-- |The static data for route messages
data Message = NLinkMsg
    {
      interfaceType  :: LinkType
    , interfaceIndex :: Word32
    , interfaceFlags :: Word32 -- ^ System.Linux.Netlink.Constants.fIFF_* flags
    }
             | NAddrMsg
    {
      addrFamily         :: AddressFamily
    , addrMaskLength     :: Word8
    , addrFlags          :: Word8
    , addrScope          :: Word8
    , addrInterfaceIndex :: Word32
    } 
             | NNeighMsg
    { neighFamily  :: Word8 -- ^ One of System.Linux.Netlink.Constants.eAF_* values
    , neighIfindex :: Int32
    , neighState   :: Word16 -- ^ System.Linux.Netlink.Constants.fNUD_* flags
    , neighFlags   :: Word8
    , neighType    :: Word8
    } deriving (Eq)

instance Show Message where
  show (NLinkMsg t i f) =
    "LinkMessage. Type: " ++ showLinkType t ++ ", Index: " ++ show i ++ ", Flags: " ++ show f
  show (NAddrMsg f l fl s i) =
    "AddrMessage. Family: " ++ show f ++ ", MLength: " ++ show l ++ ", Flags: " ++ 
    show fl ++ ", Scope: " ++ show s ++ ", Index: " ++ show i
  show (NNeighMsg f i s fl t) =
    "NeighMessage. Family: " ++ show f ++ ", Index: " ++ show i ++ ", State: " ++ 
    show s ++ ", Flags: " ++ show fl ++ ", Type: " ++ show t

instance Convertable Message where
  getGet = getMessage
  getPut = putMessage

-- |Typedef for route messages
type RoutePacket = Packet Message

showRouteHeader :: Header -> String
showRouteHeader (Header t f s p) =
  "Type: " ++ showMessageType t ++ ", Flags: " ++ (show f) ++ ", Seq: " ++ show s ++ ", Pid: " ++ show p


instance Show RoutePacket where
  showList xs = ((concat . intersperse "===\n" . map show $xs) ++)
  show (Packet hdr cus attrs) =
    "RoutePacket: " ++ showRouteHeader hdr ++ "\n" ++
    show cus ++ "\n" ++
    --TODO: is this the case every time? maybe match on other to get which enum to use
    "Attrs: \n" ++ concatMap (showMsgAttr (messageType hdr)) (toList attrs) ++ "\n"
  show p = showPacket p


showMsgAttr :: MessageType -> (Int, ByteString) -> String
showMsgAttr msgType
  | msgType == eRTM_NEWNEIGH = showNeighAttr
  | msgType == eRTM_DELNEIGH = showNeighAttr
  | msgType == eRTM_GETNEIGH = showNeighAttr
  | otherwise = showLinkAttr --default to original behavior

showNeighAttr :: (Int, ByteString) -> String
showNeighAttr = showAttr showNeighAttrType

showLinkAttr :: (Int, ByteString) -> String
showLinkAttr (i, v)
  | i == eIFLA_STATS64 = "IFLA_STATS64:\n" ++ showStats64 v
  | i == eIFLA_STATS = "IFLA_STATS:\n" ++ showStats32 v
  | i == eIFLA_AF_SPEC = 
    "eIFLA_AF_SPEC: " ++ show (BS.length v) ++ '\n':indent (showAfSpec v)
  | otherwise = showAttr showLinkAttrType (i, v)

showStats64 :: ByteString -> String
showStats64 bs = case runGet getLinkStat64 bs of
  (Left x) -> error ("Could not marshall LinkStat64: " ++ x)
  (Right x) -> show x ++ "\n"

showStats32 :: ByteString -> String
showStats32 bs = case runGet getLinkStat32 bs of
  (Left x) -> error ("Could not marshall LinkStat32: " ++ x)
  (Right x) -> show x ++ "\n"


showAfSpec :: ByteString -> String
showAfSpec bs = case runGet getAttributes bs of
  (Left x) -> error ("Could not marshall AfSpec: " ++ x)
  (Right attrs) -> 
    concatMap (\(i, v) -> showAddressFamily i ++ '\n': indent (showAfSpec' v)) (toList attrs)

showAfSpec' :: ByteString -> String
showAfSpec' bs = case runGet getAttributes bs of
  (Left x) -> error ("Could not marshall AfSpec': " ++ x)
  (Right attrs) -> showNLAttrs attrs


--
-- New generic stuffs
--

getMessage :: MessageType -> Get Message
getMessage msgtype | msgtype == eRTM_NEWLINK = getMessageLink
                   | msgtype == eRTM_GETLINK = getMessageLink
                   | msgtype == eRTM_DELLINK = getMessageLink
                   | msgtype == eRTM_NEWADDR = getMessageAddr
                   | msgtype == eRTM_GETADDR = getMessageAddr
                   | msgtype == eRTM_DELADDR = getMessageAddr

                   | msgtype == eRTM_GETNEIGH = getMessageNeigh
                   | msgtype == eRTM_NEWNEIGH = getMessageNeigh
                   | msgtype == eRTM_DELNEIGH = getMessageNeigh

                   | otherwise               =
                       error $ "Can't decode message " ++ show msgtype

getMessageLink :: Get Message
getMessageLink = do
    skip 2
    ty    <- fromIntegral <$> g16
    idx   <- g32
    flags <- g32
    skip 4
    return $ NLinkMsg ty idx flags

getMessageAddr :: Get Message
getMessageAddr = do
    fam <- fromIntegral <$> g8
    maskLen <- g8
    flags <- g8
    scope <- fromIntegral <$> g8
    idx <- g32
    return $ NAddrMsg fam maskLen flags scope idx

getMessageNeigh :: Get Message
getMessageNeigh = NNeighMsg
    <$> g8
    <*> (skip 3 >> fromIntegral <$> g32)
    <*> g16
    <*> g8
    <*> g8

putMessage :: Message -> Put
putMessage (NLinkMsg ty idx flags) = do
    p8 eAF_UNSPEC >> p8 0
    p16 (fromIntegral ty)
    p32 idx
    p32 flags
    p32 0xFFFFFFFF
putMessage (NAddrMsg fam maskLen flags scope idx) = do
    p8 (fromIntegral fam)
    p8 maskLen
    p8 flags
    p8 (fromIntegral scope)
    p32 idx
putMessage (NNeighMsg f i s fl t) = do
    p8 f
    p8 0 >> p8 0 >> p8 0 --padding
    p32 (fromIntegral i)
    p16 s
    p8 fl
    p8 t

-- |'Get' a route message or an error
getRoutePackets :: ByteString -> Either String [RoutePacket]
getRoutePackets = getPackets

-- |typedef for utility functions
type AttributeReader a = Attributes -> Maybe a

-- |typedef for utility functions
type AttributeWriter a = a -> Attributes -> Attributes

--
-- Link message attributes
--
type LinkAddress = (Word8, Word8, Word8, Word8, Word8, Word8)

-- |get L2 address from netlink attributes
getLinkAddress :: AttributeReader LinkAddress
getLinkAddress attrs = decodeMAC <$> lookup eIFLA_ADDRESS attrs

-- |set L2 address on netlink attributes
putLinkAddress :: AttributeWriter LinkAddress
putLinkAddress addr = insert eIFLA_ADDRESS (encodeMAC addr)

-- |get L2 broadcast address from netlink attributes
getLinkBroadcast :: AttributeReader LinkAddress
getLinkBroadcast attrs = decodeMAC <$> lookup eIFLA_BROADCAST attrs

-- |set L2 broadcast address on netlink attributes
putLinkBroadcast :: AttributeWriter LinkAddress
putLinkBroadcast addr = insert eIFLA_BROADCAST (encodeMAC addr)

-- |get interface name from netlink attributes
getLinkName :: AttributeReader String
getLinkName attrs = getString <$> lookup eIFLA_IFNAME attrs

-- |set interface name on netlink attributes
putLinkName :: AttributeWriter String
putLinkName ifname = insert eIFLA_IFNAME (putString ifname)

-- |get mtu from netlink attributes
getLinkMTU :: AttributeReader Word32
getLinkMTU attrs = get32 =<< lookup eIFLA_MTU attrs

-- |set mtu on netlink attributes
putLinkMTU :: AttributeWriter Word32
putLinkMTU mtu = insert eIFLA_MTU (put32 mtu)

-- TODO: IFLA_LINK - need to understand what it does

-- |I actually have no idea what QDisc is
getLinkQDisc :: AttributeReader String
getLinkQDisc attrs = getString <$> lookup eIFLA_QDISC attrs

-- |I actually have no idea what QDisc is
putLinkQDisc :: AttributeWriter String
putLinkQDisc disc = insert eIFLA_QDISC (putString disc)

-- TODO: IFLA_STATS - bloody huge message, will deal with it later.

-- TODO: IFLA_{COST,PRIORITY,MASTER,WIRELESS,PROTINFO} - need to
-- understand what they do.

-- |I should look this up
getLinkTXQLen :: AttributeReader Word32
getLinkTXQLen attrs = get32 =<< lookup eIFLA_TXQLEN attrs

-- |I should look this up
putLinkTXQLen :: AttributeWriter Word32
putLinkTXQLen len = insert eIFLA_TXQLEN (put32 len)

-- TODO: IFLA_{MAP,WEIGHT} - need to figure out

-- TODO: IFLA_{LINKMODE,LINKINFO} - see Documentation/networking/operstates.txt

-- TODO: IFLA_{NET_NS_PID,IFALIAS} - need to figure out

-- |get interface address from netlink attributes of 'NAddrMsg'
getIFAddr :: AttributeReader ByteString
getIFAddr = lookup eIFA_ADDRESS

-- |get L2 address from netlink attributes of 'NNeighMsg'
getLLAddr :: AttributeReader LinkAddress
getLLAddr attrs = decodeMAC <$> lookup eNDA_LLADDR attrs

-- |get destination address from netlink attributes of 'NNeighMsg'
getDstAddr :: AttributeReader ByteString
getDstAddr = lookup eNDA_DST

--
-- Helpers
--

decodeMAC :: ByteString -> LinkAddress
decodeMAC = tuplify . map (fromIntegral . ord) . unpack
  where tuplify [a,b,c,d,e,f] = (a,b,c,d,e,f)
        tuplify _ = error "Bad encoded MAC"

encodeMAC :: LinkAddress -> ByteString
encodeMAC = pack . map (chr . fromIntegral) . listify
  where listify (a,b,c,d,e,f) = [a,b,c,d,e,f]

getString :: ByteString -> String
getString b = unpack (init b)

putString :: String -> ByteString
putString s = append (pack s) "\0"

get32 :: ByteString -> Maybe Word32
get32 bs = case runGet getWord32host bs of
    Left  _ -> Nothing
    Right w -> Just w

put32 :: Word32 -> ByteString
put32 w = runPut (putWord32host w)
