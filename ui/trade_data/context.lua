local rootEnv = getfenv(1)
MyTradeTab = MyTradeTab or {}
MyTradeTab._rootEnv = MyTradeTab._rootEnv or rootEnv
setmetatable(MyTradeTab, { __index = MyTradeTab._rootEnv })
setfenv(1, MyTradeTab)
ffi = require("ffi")
C = ffi.C

ffi.cdef[[
typedef uint64_t UniverseID;
typedef struct {
  const char* name;
  const char* transport;
  uint32_t spaceused;
  uint32_t capacity;
} StorageInfo;
UniverseID GetPlayerID(void);
UniverseID GetContextByClass(UniverseID componentid, const char* classname, bool includeself);
void SetFocusMapComponent(UniverseID holomapid, UniverseID componentid, bool force);
uint32_t GetCargoTransportTypes(StorageInfo* result, uint32_t resultlen, UniverseID containerid, bool merge, bool aftertradeorders);
uint32_t GetNumCargoTransportTypes(UniverseID containerid, bool merge);
]]

MODE = "trade_data"
TAB_ICON = "mapst_fs_trade"
tradeTab = {
  menuMap = nil,
  menuMapConfig = nil,
  stationCache = {},
  cachedDataset = nil,
  datasetDirty = true,
  gateDistanceFilterPending = false,
  tradeDistanceCachePending = {},
  exactTradeDistanceCache = {},
  tradeDistanceRequestsRemaining = 0,
  activeTab = "best",
  tableState = {
    leftTopRow = nil,
    rightTopRow = nil,
  },
  filters = {
    mode = "best",
    ware = "__all__",
    sector = "__all__",
    faction = "__all__",
    illegal = "hide",
    wareSelection = {},
    sectorSelection = {},
    factionSelection = {},
    originSector = nil,
    maxGateDistance = "0",
    maxTradeDistance = "0",
    cargoVolume = "5000",
  },
}

getReachableSectors = nil
normalizeCargoVolume = nil
wareVolumeCache = {}
wareRowColors = {
  black = { r = 0, g = 0, b = 0, a = 40 },
  darkGray = { r = 28, g = 28, b = 28, a = 40 },
}
buyerRowColors = {
  background = { r = 32, g = 46, b = 64, a = 58 },
  highlight = { r = 48, g = 68, b = 92, a = 80 },
  selected = { r = 62, g = 90, b = 122, a = 78 },
}
sellerRowColors = {
  selected = { r = 52, g = 86, b = 124, a = 72 },
}

