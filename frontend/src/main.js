import { ethers } from "ethers";
import { LMSR_BETTING_ABI } from "./abi.js";

const STORAGE_KEY = "lmsr-betting.contract-address";
const ANVIL_CHAIN_ID = 31337n;
const BPS_DENOMINATOR = 10_000n;

let provider;
let signer;
let contract;
let activeAccount = null;
let ownerAddress = null;
let feeBps = 0n;

const el = {
  connectBtn: document.getElementById("connect-btn"),
  refreshBtn: document.getElementById("refresh-btn"),
  saveContractBtn: document.getElementById("save-contract-btn"),
  contractAddress: document.getElementById("contract-address"),
  walletStatus: document.getElementById("wallet-status"),
  ownerAddress: document.getElementById("owner-address"),
  feeBps: document.getElementById("fee-bps"),
  status: document.getElementById("status"),
  createMarketForm: document.getElementById("create-market-form"),
  markets: document.getElementById("markets")
};

function setStatus(message, tone = "info") {
  const tones = {
    info: "bg-slate-50 text-slate-700",
    success: "bg-emerald-50 text-emerald-800",
    warn: "bg-amber-50 text-amber-800",
    error: "bg-rose-50 text-rose-800"
  };

  el.status.textContent = message;
  el.status.className = `mt-4 rounded-lg px-3 py-2 text-sm ${tones[tone] || tones.info}`;
}

function readableError(error) {
  if (error?.shortMessage) return error.shortMessage;
  if (error?.reason) return error.reason;
  if (error?.message) return error.message;
  return String(error);
}

function shortAddress(address) {
  if (!address) return "-";
  return `${address.slice(0, 6)}...${address.slice(-4)}`;
}

function formatEth(value) {
  return Number.parseFloat(ethers.formatEther(value)).toFixed(6);
}

function formatPricePercent(wadValue) {
  return Number.parseFloat(ethers.formatUnits(wadValue, 16)).toFixed(2);
}

function formatTimestamp(unixSeconds) {
  const date = new Date(Number(unixSeconds) * 1000);
  return date.toLocaleString();
}

function parseEthInput(value, fieldName) {
  if (!value || value.trim() === "") {
    throw new Error(`${fieldName} is required.`);
  }

  const parsed = ethers.parseEther(value);
  if (parsed <= 0n) {
    throw new Error(`${fieldName} must be greater than 0.`);
  }

  return parsed;
}

function parseSlippageBps(value) {
  const parsed = Number.parseInt(value || "100", 10);
  if (!Number.isFinite(parsed) || parsed < 0 || parsed > 5000) {
    throw new Error("Slippage must be between 0 and 5000 bps.");
  }
  return parsed;
}

function escapeHtml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function renderEmptyMarkets(message) {
  el.markets.innerHTML = `<p class="rounded-xl bg-white p-4 text-sm text-slate-500 shadow-sm ring-1 ring-slate-200">${message}</p>`;
}

function loadSavedAddress() {
  const saved = window.localStorage.getItem(STORAGE_KEY) || "";
  el.contractAddress.value = saved;
}

function saveAddress() {
  const address = el.contractAddress.value.trim();
  if (!ethers.isAddress(address)) {
    setStatus("Please enter a valid contract address.", "error");
    return;
  }

  window.localStorage.setItem(STORAGE_KEY, address);
  setStatus("Contract address saved.", "success");

  if (provider && signer) {
    void initContract();
  }
}

async function connectWallet() {
  if (!window.ethereum) {
    setStatus("MetaMask not detected. Install MetaMask to continue.", "error");
    return;
  }

  try {
    provider = new ethers.BrowserProvider(window.ethereum);
    await provider.send("eth_requestAccounts", []);

    signer = await provider.getSigner();
    activeAccount = await signer.getAddress();

    const network = await provider.getNetwork();
    el.walletStatus.textContent = `${shortAddress(activeAccount)} (chain ${network.chainId})`;

    if (network.chainId !== ANVIL_CHAIN_ID) {
      setStatus(
        `Connected to chain ${network.chainId}. Expected 31337 for Anvil.`,
        "warn"
      );
    } else {
      setStatus("Wallet connected.", "success");
    }

    await initContract();
  } catch (error) {
    setStatus(`Failed to connect wallet: ${readableError(error)}`, "error");
  }
}

async function initContract() {
  const address = el.contractAddress.value.trim();

  if (!ethers.isAddress(address)) {
    contract = undefined;
    ownerAddress = null;
    feeBps = 0n;
    el.ownerAddress.textContent = "-";
    el.feeBps.textContent = "-";
    renderEmptyMarkets("Set a valid contract address, then click Refresh.");
    return;
  }

  contract = new ethers.Contract(address, LMSR_BETTING_ABI, signer);

  try {
    ownerAddress = await contract.owner();
    feeBps = await contract.feeBps();

    el.ownerAddress.textContent = ownerAddress;
    el.feeBps.textContent = feeBps.toString();

    await renderMarkets();
  } catch (error) {
    contract = undefined;
    ownerAddress = null;
    feeBps = 0n;
    el.ownerAddress.textContent = "-";
    el.feeBps.textContent = "-";
    renderEmptyMarkets("Unable to read markets from contract.");
    setStatus(`Contract read failed: ${readableError(error)}`, "error");
  }
}

async function createMarket(event) {
  event.preventDefault();

  if (!contract) {
    setStatus("Connect wallet and set a valid contract address first.", "warn");
    return;
  }

  const form = event.currentTarget;

  try {
    const title = form.title.value.trim();
    if (!title) throw new Error("Title is required.");

    const closeInput = form.close.value;
    if (!closeInput) throw new Error("Close time is required.");

    const closeTimestamp = Math.floor(new Date(closeInput).getTime() / 1000);
    if (!Number.isFinite(closeTimestamp) || closeTimestamp <= Math.floor(Date.now() / 1000)) {
      throw new Error("Close time must be in the future.");
    }

    const bWei = parseEthInput(form.b.value, "Liquidity parameter b");
    const fundingWei = parseEthInput(form.funding.value, "Initial funding");

    const requiredFunding = await contract.requiredSubsidy(bWei);
    if (fundingWei < requiredFunding) {
      throw new Error(
        `Initial funding must be at least ${formatEth(requiredFunding)} ETH for this b value.`
      );
    }

    setStatus("Creating market transaction...", "info");
    const tx = await contract.createMarket(title, BigInt(closeTimestamp), bWei, {
      value: fundingWei
    });
    await tx.wait();

    setStatus("Market created.", "success");
    await renderMarkets();
  } catch (error) {
    setStatus(`Create market failed: ${readableError(error)}`, "error");
  }
}

async function loadMarket(marketId) {
  const market = await contract.getMarket(marketId);
  const prices = await contract.getPriceWad(marketId);

  let userYes = 0n;
  let userNo = 0n;

  if (activeAccount) {
    const userShares = await contract.getUserShares(marketId, activeAccount);
    userYes = userShares[0];
    userNo = userShares[1];
  }

  return {
    id: marketId,
    title: market[0],
    closeTime: Number(market[1]),
    b: market[2],
    qYes: market[3],
    qNo: market[4],
    pool: market[5],
    resolved: market[6],
    winningOutcome: Number(market[7]),
    creator: market[8],
    yesPriceWad: prices[0],
    noPriceWad: prices[1],
    userYes,
    userNo
  };
}

async function renderMarkets() {
  if (!contract) {
    renderEmptyMarkets("Connect wallet and set a contract address to load markets.");
    return;
  }

  try {
    const count = Number(await contract.marketCount());
    if (count === 0) {
      renderEmptyMarkets("No markets created yet.");
      return;
    }

    const cards = [];

    for (let id = count - 1; id >= 0; id -= 1) {
      const market = await loadMarket(id);
      cards.push(buildMarketCard(market));
    }

    el.markets.replaceChildren(...cards);
  } catch (error) {
    renderEmptyMarkets("Failed to load markets.");
    setStatus(`Failed to load markets: ${readableError(error)}`, "error");
  }
}

function buildMarketCard(market) {
  const nowSeconds = Math.floor(Date.now() / 1000);
  const isOpen = !market.resolved && market.closeTime > nowSeconds;
  const isOwner =
    !!activeAccount && !!ownerAddress && activeAccount.toLowerCase() === ownerAddress.toLowerCase();

  const card = document.createElement("article");
  card.className = "rounded-2xl bg-white p-5 shadow-sm ring-1 ring-slate-200";

  const safeTitle = escapeHtml(market.title);
  const safeCreator = escapeHtml(market.creator);

  card.innerHTML = `
    <div class="space-y-4">
      <div>
        <h3 class="text-base font-semibold text-slate-900">${safeTitle}</h3>
        <p class="mt-1 text-xs text-slate-500">Market #${market.id} • creator ${safeCreator}</p>
      </div>

      <dl class="grid grid-cols-2 gap-x-3 gap-y-2 text-sm">
        <dt class="text-slate-500">Close time</dt>
        <dd>${formatTimestamp(market.closeTime)}</dd>

        <dt class="text-slate-500">Status</dt>
        <dd>${market.resolved ? `Resolved (${market.winningOutcome === 0 ? "YES" : "NO"})` : isOpen ? "Open" : "Closed"}</dd>

        <dt class="text-slate-500">b (ETH)</dt>
        <dd>${formatEth(market.b)}</dd>

        <dt class="text-slate-500">Pool (ETH)</dt>
        <dd>${formatEth(market.pool)}</dd>

        <dt class="text-slate-500">YES price</dt>
        <dd>${formatPricePercent(market.yesPriceWad)}%</dd>

        <dt class="text-slate-500">NO price</dt>
        <dd>${formatPricePercent(market.noPriceWad)}%</dd>

        <dt class="text-slate-500">Your YES shares</dt>
        <dd>${formatEth(market.userYes)}</dd>

        <dt class="text-slate-500">Your NO shares</dt>
        <dd>${formatEth(market.userNo)}</dd>
      </dl>

      <form data-action="buy" class="rounded-xl border border-slate-200 p-3 ${isOpen ? "" : "opacity-60"}">
        <h4 class="mb-2 text-sm font-medium">Buy</h4>
        <div class="grid grid-cols-3 gap-2">
          <select name="outcome" class="rounded border border-slate-300 px-2 py-1.5 text-sm" ${isOpen ? "" : "disabled"}>
            <option value="0">YES</option>
            <option value="1">NO</option>
          </select>
          <input name="shares" type="number" min="0" step="0.000001" placeholder="Shares (ETH)" class="rounded border border-slate-300 px-2 py-1.5 text-sm" ${isOpen ? "" : "disabled"} required />
          <input name="slippage" type="number" min="0" max="5000" step="1" value="100" placeholder="Slippage bps" class="rounded border border-slate-300 px-2 py-1.5 text-sm" ${isOpen ? "" : "disabled"} required />
        </div>
        <button type="submit" class="mt-2 w-full rounded bg-emerald-600 px-3 py-2 text-sm font-medium text-white hover:bg-emerald-500" ${isOpen ? "" : "disabled"}>Buy Shares</button>
      </form>

      <form data-action="sell" class="rounded-xl border border-slate-200 p-3 ${isOpen ? "" : "opacity-60"}">
        <h4 class="mb-2 text-sm font-medium">Sell</h4>
        <div class="grid grid-cols-3 gap-2">
          <select name="outcome" class="rounded border border-slate-300 px-2 py-1.5 text-sm" ${isOpen ? "" : "disabled"}>
            <option value="0">YES</option>
            <option value="1">NO</option>
          </select>
          <input name="shares" type="number" min="0" step="0.000001" placeholder="Shares (ETH)" class="rounded border border-slate-300 px-2 py-1.5 text-sm" ${isOpen ? "" : "disabled"} required />
          <input name="slippage" type="number" min="0" max="5000" step="1" value="100" placeholder="Slippage bps" class="rounded border border-slate-300 px-2 py-1.5 text-sm" ${isOpen ? "" : "disabled"} required />
        </div>
        <button type="submit" class="mt-2 w-full rounded bg-amber-600 px-3 py-2 text-sm font-medium text-white hover:bg-amber-500" ${isOpen ? "" : "disabled"}>Sell Shares</button>
      </form>

      ${
        isOwner && !market.resolved
          ? `
            <form data-action="resolve" class="rounded-xl border border-slate-200 p-3">
              <h4 class="mb-2 text-sm font-medium">Resolve (Owner Only)</h4>
              <div class="grid grid-cols-2 gap-2">
                <select name="winningOutcome" class="rounded border border-slate-300 px-2 py-1.5 text-sm">
                  <option value="0">YES wins</option>
                  <option value="1">NO wins</option>
                </select>
                <button type="submit" class="rounded bg-indigo-700 px-3 py-2 text-sm font-medium text-white hover:bg-indigo-600">Resolve Market</button>
              </div>
            </form>
          `
          : ""
      }

      ${
        market.resolved
          ? '<button data-action="claim" type="button" class="w-full rounded bg-slate-900 px-3 py-2 text-sm font-medium text-white hover:bg-slate-800">Claim Winnings</button>'
          : ""
      }
    </div>
  `;

  const buyForm = card.querySelector('form[data-action="buy"]');
  buyForm.addEventListener("submit", (event) => {
    void handleBuy(event, market.id);
  });

  const sellForm = card.querySelector('form[data-action="sell"]');
  sellForm.addEventListener("submit", (event) => {
    void handleSell(event, market.id);
  });

  const resolveForm = card.querySelector('form[data-action="resolve"]');
  if (resolveForm) {
    resolveForm.addEventListener("submit", (event) => {
      void handleResolve(event, market.id);
    });
  }

  const claimButton = card.querySelector('button[data-action="claim"]');
  if (claimButton) {
    claimButton.addEventListener("click", () => {
      void handleClaim(market.id);
    });
  }

  return card;
}

async function handleBuy(event, marketId) {
  event.preventDefault();

  if (!contract) {
    setStatus("Contract not initialized.", "warn");
    return;
  }

  const form = event.currentTarget;

  try {
    const outcome = Number.parseInt(form.outcome.value, 10);
    const shares = parseEthInput(form.shares.value, "Shares");
    const slippageBps = parseSlippageBps(form.slippage.value);

    const quotedCost = await contract.quoteBuyCost(marketId, outcome, shares);
    const maxCost = quotedCost + (quotedCost * BigInt(slippageBps)) / BPS_DENOMINATOR;
    const maxFee = (maxCost * feeBps) / BPS_DENOMINATOR;

    setStatus(`Submitting buy tx for market #${marketId}...`, "info");
    const tx = await contract.buy(marketId, outcome, shares, maxCost, {
      value: maxCost + maxFee
    });
    await tx.wait();

    setStatus("Buy transaction confirmed.", "success");
    await renderMarkets();
  } catch (error) {
    setStatus(`Buy failed: ${readableError(error)}`, "error");
  }
}

async function handleSell(event, marketId) {
  event.preventDefault();

  if (!contract) {
    setStatus("Contract not initialized.", "warn");
    return;
  }

  const form = event.currentTarget;

  try {
    const outcome = Number.parseInt(form.outcome.value, 10);
    const shares = parseEthInput(form.shares.value, "Shares");
    const slippageBps = parseSlippageBps(form.slippage.value);

    const quotedPayout = await contract.quoteSellPayout(marketId, outcome, shares);
    const minPayout = quotedPayout - (quotedPayout * BigInt(slippageBps)) / BPS_DENOMINATOR;

    setStatus(`Submitting sell tx for market #${marketId}...`, "info");
    const tx = await contract.sell(marketId, outcome, shares, minPayout);
    await tx.wait();

    setStatus("Sell transaction confirmed.", "success");
    await renderMarkets();
  } catch (error) {
    setStatus(`Sell failed: ${readableError(error)}`, "error");
  }
}

async function handleResolve(event, marketId) {
  event.preventDefault();

  if (!contract) {
    setStatus("Contract not initialized.", "warn");
    return;
  }

  const form = event.currentTarget;

  try {
    const winningOutcome = Number.parseInt(form.winningOutcome.value, 10);

    setStatus(`Resolving market #${marketId}...`, "info");
    const tx = await contract.resolve(marketId, winningOutcome);
    await tx.wait();

    setStatus("Market resolved.", "success");
    await renderMarkets();
  } catch (error) {
    setStatus(`Resolve failed: ${readableError(error)}`, "error");
  }
}

async function handleClaim(marketId) {
  if (!contract) {
    setStatus("Contract not initialized.", "warn");
    return;
  }

  try {
    setStatus(`Claiming winnings from market #${marketId}...`, "info");
    const tx = await contract.claim(marketId);
    await tx.wait();

    setStatus("Claim transaction confirmed.", "success");
    await renderMarkets();
  } catch (error) {
    setStatus(`Claim failed: ${readableError(error)}`, "error");
  }
}

function bindWalletListeners() {
  if (!window.ethereum?.on) return;

  window.ethereum.on("accountsChanged", async (accounts) => {
    if (!accounts || accounts.length === 0) {
      activeAccount = null;
      signer = undefined;
      contract = undefined;
      el.walletStatus.textContent = "Not connected";
      renderEmptyMarkets("Wallet disconnected.");
      setStatus("Wallet disconnected.", "warn");
      return;
    }

    if (provider) {
      signer = await provider.getSigner();
      activeAccount = await signer.getAddress();
      el.walletStatus.textContent = shortAddress(activeAccount);
      await initContract();
    }
  });

  window.ethereum.on("chainChanged", () => {
    window.location.reload();
  });
}

function bindUi() {
  el.connectBtn.addEventListener("click", () => {
    void connectWallet();
  });

  el.refreshBtn.addEventListener("click", () => {
    void renderMarkets();
  });

  el.saveContractBtn.addEventListener("click", () => {
    saveAddress();
  });

  el.createMarketForm.addEventListener("submit", (event) => {
    void createMarket(event);
  });
}

function bootstrap() {
  loadSavedAddress();
  bindUi();
  bindWalletListeners();
  renderEmptyMarkets("Connect wallet and set a contract address to load markets.");
  setStatus("Ready.", "info");
}

bootstrap();
