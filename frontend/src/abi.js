export const LMSR_BETTING_ABI = [
  {
    type: "function",
    name: "owner",
    inputs: [],
    outputs: [{ name: "", type: "address", internalType: "address" }],
    stateMutability: "view"
  },
  {
    type: "function",
    name: "feeBps",
    inputs: [],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view"
  },
  {
    type: "function",
    name: "marketCount",
    inputs: [],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view"
  },
  {
    type: "function",
    name: "requiredSubsidy",
    inputs: [{ name: "b", type: "uint256", internalType: "uint256" }],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "pure"
  },
  {
    type: "function",
    name: "createMarket",
    inputs: [
      { name: "title", type: "string", internalType: "string" },
      { name: "closeTime", type: "uint64", internalType: "uint64" },
      { name: "b", type: "uint256", internalType: "uint256" }
    ],
    outputs: [{ name: "marketId", type: "uint256", internalType: "uint256" }],
    stateMutability: "payable"
  },
  {
    type: "function",
    name: "getMarket",
    inputs: [{ name: "marketId", type: "uint256", internalType: "uint256" }],
    outputs: [
      { name: "title", type: "string", internalType: "string" },
      { name: "closeTime", type: "uint64", internalType: "uint64" },
      { name: "b", type: "uint256", internalType: "uint256" },
      { name: "qYes", type: "uint256", internalType: "uint256" },
      { name: "qNo", type: "uint256", internalType: "uint256" },
      { name: "pool", type: "uint256", internalType: "uint256" },
      { name: "resolved", type: "bool", internalType: "bool" },
      { name: "winningOutcome", type: "uint8", internalType: "uint8" },
      { name: "creator", type: "address", internalType: "address" }
    ],
    stateMutability: "view"
  },
  {
    type: "function",
    name: "getPriceWad",
    inputs: [{ name: "marketId", type: "uint256", internalType: "uint256" }],
    outputs: [
      { name: "yesPriceWad", type: "uint256", internalType: "uint256" },
      { name: "noPriceWad", type: "uint256", internalType: "uint256" }
    ],
    stateMutability: "view"
  },
  {
    type: "function",
    name: "getUserShares",
    inputs: [
      { name: "marketId", type: "uint256", internalType: "uint256" },
      { name: "user", type: "address", internalType: "address" }
    ],
    outputs: [
      { name: "yesShares", type: "uint256", internalType: "uint256" },
      { name: "noShares", type: "uint256", internalType: "uint256" }
    ],
    stateMutability: "view"
  },
  {
    type: "function",
    name: "quoteBuyCost",
    inputs: [
      { name: "marketId", type: "uint256", internalType: "uint256" },
      { name: "outcome", type: "uint8", internalType: "uint8" },
      { name: "shares", type: "uint256", internalType: "uint256" }
    ],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view"
  },
  {
    type: "function",
    name: "quoteSellPayout",
    inputs: [
      { name: "marketId", type: "uint256", internalType: "uint256" },
      { name: "outcome", type: "uint8", internalType: "uint8" },
      { name: "shares", type: "uint256", internalType: "uint256" }
    ],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view"
  },
  {
    type: "function",
    name: "buy",
    inputs: [
      { name: "marketId", type: "uint256", internalType: "uint256" },
      { name: "outcome", type: "uint8", internalType: "uint8" },
      { name: "shares", type: "uint256", internalType: "uint256" },
      { name: "maxCost", type: "uint256", internalType: "uint256" }
    ],
    outputs: [],
    stateMutability: "payable"
  },
  {
    type: "function",
    name: "sell",
    inputs: [
      { name: "marketId", type: "uint256", internalType: "uint256" },
      { name: "outcome", type: "uint8", internalType: "uint8" },
      { name: "shares", type: "uint256", internalType: "uint256" },
      { name: "minPayout", type: "uint256", internalType: "uint256" }
    ],
    outputs: [],
    stateMutability: "nonpayable"
  },
  {
    type: "function",
    name: "resolve",
    inputs: [
      { name: "marketId", type: "uint256", internalType: "uint256" },
      { name: "winningOutcome", type: "uint8", internalType: "uint8" }
    ],
    outputs: [],
    stateMutability: "nonpayable"
  },
  {
    type: "function",
    name: "claim",
    inputs: [{ name: "marketId", type: "uint256", internalType: "uint256" }],
    outputs: [],
    stateMutability: "nonpayable"
  }
];
