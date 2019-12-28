import
  tables, json, strutils,
  eth/[common, rlp, trie], stint, stew/[byteutils, ranges],
  chronicles, eth/trie/db,
  db/[db_chain, state_db], genesis_alloc, config, constants

type
  Genesis* = object
    config*: ChainConfig
    nonce*: BlockNonce
    timestamp*: EthTime
    extraData*: seq[byte]
    gasLimit*: GasInt
    difficulty*: DifficultyInt
    mixhash*: Hash256
    coinbase*: EthAddress
    alloc*: GenesisAlloc

  GenesisAlloc = TableRef[EthAddress, GenesisAccount]
  GenesisAccount = object
    code*: seq[byte]
    storage*: Table[UInt256, UInt256]
    balance*: UInt256
    nonce*: AccountNonce

func toAddress(n: UInt256): EthAddress =
  let a = n.toByteArrayBE()
  result[0 .. ^1] = a.toOpenArray(12, a.high)

func decodePrealloc(data: seq[byte]): GenesisAlloc =
  result = newTable[EthAddress, GenesisAccount]()
  for tup in rlp.decode(data.toRange, seq[(UInt256, UInt256)]):
    result[toAddress(tup[0])] = GenesisAccount(balance: tup[1])

func customNetPrealloc(genesisBlock: JsonNode): GenesisAlloc = 
  result = newTable[EthAddress, GenesisAccount]()
  for address, balance in genesisBlock["alloc"].pairs():
    var balance = balance["balance"].getStr()
    result[parseAddress(address)] = GenesisAccount(balance: cast[UInt256](balance))

proc defaultGenesisBlockForNetwork*(id: PublicNetwork): Genesis =
  result = case id
  of MainNet:
    Genesis(
      nonce: 66.toBlockNonce,
      extraData: hexToSeqByte("0x11bbe8db4e347b4e8c937c1c8370e4b5ed33adb3db69cbdb7a38e1e50b1b82fa"),
      gasLimit: 5000,
      difficulty: 17179869184.u256,
      alloc: decodePrealloc(mainnetAllocData)
    )
  of RopstenNet:
    Genesis(
      nonce: 66.toBlockNonce,
      extraData: hexToSeqByte("0x3535353535353535353535353535353535353535353535353535353535353535"),
      gasLimit: 16777216,
      difficulty: 1048576.u256,
      alloc: decodePrealloc(testnetAllocData)
    )
  of RinkebyNet:
    Genesis(
      nonce: 66.toBlockNonce,
      extraData: hexToSeqByte("0x3535353535353535353535353535353535353535353535353535353535353535"),
      gasLimit: 16777216,
      difficulty: 1048576.u256,
      alloc: decodePrealloc(rinkebyAllocData)
    )
  of CustomNet:
    let genesis = getConfiguration().genesisBlock
    var nonce = 66.toBlockNonce
    if genesis.hasKey("nonce"):
      nonce = (parseHexInt(genesis["nonce"].getStr()).uint64).toBlockNonce
    var extraData = hexToSeqByte("")
    if genesis.hasKey("extraData"):
      extraData = hexToSeqByte(genesis["extraData"].getStr())
    var gasLimit = 16777216
    if genesis.hasKey("gasLimit"):
      gasLimit = parseHexInt(genesis["gasLimit"].getStr())
    var difficulty = 1048576.u256
    if genesis.hasKey("difficulty"):
      difficulty = parseHexInt(genesis["difficulty"].getStr()).u256
    var alloc = new GenesisAlloc
    if genesis.hasKey("alloc"):
      alloc = customNetPrealloc(genesis)
    Genesis(
      nonce: nonce,
      extraData: extraData,
      gasLimit: gasLimit,
      difficulty: difficulty,
      alloc: alloc
    )
  else:
    # TODO: Fill out the rest
    error "No default genesis for network", id
    doAssert(false, "No default genesis for " & $id)
    Genesis()
  if id == CustomNet:
    result.config = privateChainConfig()
  else:
    result.config = publicChainConfig(id)

proc toBlock*(g: Genesis, db: BaseChainDB = nil): BlockHeader =
  let (tdb, pruneTrie) = if db.isNil: (newMemoryDB(), true)
                         else: (db.db, db.pruneTrie)
  var trie = initHexaryTrie(tdb)
  var sdb = newAccountStateDB(tdb, trie.rootHash, pruneTrie)

  for address, account in g.alloc:
    sdb.setAccount(address, newAccount(account.nonce, account.balance))
    sdb.setCode(address, account.code.toRange)
    for k, v in account.storage:
      sdb.setStorage(address, k, v)

  var root = sdb.rootHash

  result = BlockHeader(
    nonce: g.nonce,
    timestamp: g.timestamp,
    extraData: g.extraData,
    gasLimit: g.gasLimit,
    difficulty: g.difficulty,
    mixDigest: g.mixhash,
    coinbase: g.coinbase,
    stateRoot: root,
    parentHash: GENESIS_PARENT_HASH,
    txRoot: BLANK_ROOT_HASH,
    receiptRoot: BLANK_ROOT_HASH,
    ommersHash: EMPTY_UNCLE_HASH
  )

  if g.gasLimit == 0:
    result.gasLimit = GENESIS_GAS_LIMIT

  if g.difficulty == 0:
    result.difficulty = GENESIS_DIFFICULTY

proc commit*(g: Genesis, db: BaseChainDB) =
  let b = g.toBlock(db)
  doAssert(b.blockNumber == 0, "can't commit genesis block with number > 0")
  discard db.persistHeaderToDb(b)

proc initializeEmptyDb*(db: BaseChainDB) =
  trace "Writing genesis to DB"
  let networkId = getConfiguration().net.networkId.toPublicNetwork()
#  if networkId == CustomNet:
#    raise newException(Exception, "Custom genesis not implemented")
#  else:
  defaultGenesisBlockForNetwork(networkId).commit(db)
