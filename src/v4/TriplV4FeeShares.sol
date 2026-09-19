// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ITriplLaunchStatus {
    function platformToken() external view returns (address);
}

/// @notice Exactly 100 equal-weight shares of the Triplfun NFT fee pool.
contract TriplV4FeeShares is ERC721, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidConfiguration();
    error InvalidQuantity();
    error SaleNotOpen();
    error PlatformNotLaunched();
    error Unauthorized();
    error NothingToClaim();
    error InexactTransfer();
    error MintPriceChanged();

    uint256 public constant MAX_SUPPLY = 100;
    uint256 public constant TEAM_SUPPLY = 30;
    IERC20 public immutable usdc;
    IPoolManager public immutable poolManager;
    bool private withdrawing;
    address public immutable treasury;
    address public immutable nftRecipient;
    address public immutable factory;
    /// @notice Base price: each ten public mints adds this amount to the price.
    uint256 public immutable mintPrice;
    uint256 public immutable saleStart;
    address public feeVault;
    uint256 public totalSupply;
    uint256 public totalRevenue;
    uint256 public totalClaimed;
    uint256 public mintProceeds;
    mapping(uint256 => uint256) public settledPerToken;
    mapping(address => uint256) public credits;
    string private metadataBase;

    event RevenueDeposited(address indexed sender, uint256 amount, uint256 cumulativeRevenue);
    event RevenueClaimed(address indexed holder, uint256 amount);
    event PublicMint(address indexed holder, uint256 quantity, uint256 paid);
    event MintProceedsClaimed(address indexed treasury, uint256 amount);
    event FeeVaultBound(address indexed feeVault);

    constructor(
        address usdc_,
        address treasury_,
        address nftRecipient_,
        uint256 mintPrice_,
        uint256 saleStart_,
        string memory baseURI_,
        address factory_,
        address poolManager_
    ) ERC721("tr!pl", "TR!PL") {
        if (
            usdc_ == address(0) || usdc_.code.length == 0 || treasury_ == address(0)
                || nftRecipient_ == address(0) || mintPrice_ == 0 || bytes(baseURI_).length == 0
                || factory_ == address(0) || poolManager_.code.length == 0
        ) revert InvalidConfiguration();
        try IERC20Metadata(usdc_).decimals() returns (uint8 decimals) {
            if (decimals != 6) revert InvalidConfiguration();
        } catch {
            revert InvalidConfiguration();
        }
        usdc = IERC20(usdc_);
        poolManager = IPoolManager(poolManager_);
        treasury = treasury_;
        nftRecipient = nftRecipient_;
        factory = factory_;
        mintPrice = mintPrice_;
        saleStart = saleStart_;
        metadataBase = baseURI_;
        totalSupply = TEAM_SUPPLY;
        for (uint256 tokenId = 1; tokenId <= TEAM_SUPPLY; ++tokenId) {
            _safeMint(nftRecipient_, tokenId);
        }
    }

    function bindFeeVault(address vault) external {
        if (msg.sender != factory || vault == address(0) || feeVault != address(0)) {
            revert Unauthorized();
        }
        feeVault = vault;
        emit FeeVaultBound(vault);
    }

    function mint(uint256 quantity) external nonReentrant {
        _mintPublic(quantity, type(uint256).max);
    }

    /// @notice Protects the displayed quote if another mint crosses a tier first.
    function mintWithMaxPayment(uint256 quantity, uint256 maxPayment) external nonReentrant {
        _mintPublic(quantity, maxPayment);
    }

    /// @notice Team IDs 1–30; public tiers 31–40 through 91–100.
    /// The loop is bounded to at most seven tiers, not the number of holders.
    function quoteMint(uint256 quantity) public view returns (uint256 payment) {
        if (quantity == 0 || quantity > MAX_SUPPLY - totalSupply) revert InvalidQuantity();
        uint256 sold = totalSupply - TEAM_SUPPLY;
        while (quantity != 0) {
            uint256 remainingInTier = 10 - sold % 10;
            uint256 count = quantity < remainingInTier ? quantity : remainingInTier;
            payment += count * (sold / 10 + 1) * mintPrice;
            sold += count;
            quantity -= count;
        }
    }

    function _mintPublic(uint256 quantity, uint256 maxPayment) private {
        if (block.timestamp < saleStart) revert SaleNotOpen();
        if (factory == address(0) || ITriplLaunchStatus(factory).platformToken() == address(0)) {
            revert PlatformNotLaunched();
        }
        uint256 payment = quoteMint(quantity);
        if (payment > maxPayment) revert MintPriceChanged();
        uint256 firstToken = totalSupply + 1;
        _pullExact(msg.sender, payment);
        totalSupply += quantity;
        mintProceeds += payment;
        for (uint256 offset; offset < quantity; ++offset) {
            _safeMint(msg.sender, firstToken + offset);
        }
        emit PublicMint(msg.sender, quantity, payment);
    }

    /// @dev Kept as an explicit pull entrypoint for isolated accounting tests.
    /// V4 hooks mint PoolManager claims directly to this receiver, then notify revenue.
    function depositRevenue(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidQuantity();
        _pullExact(msg.sender, amount);
        _recordRevenue(amount);
    }

    function notifyRevenue(uint256 amount) external nonReentrant {
        if (msg.sender != feeVault || amount == 0) revert Unauthorized();
        uint256 backing = usdc.balanceOf(address(this))
            + poolManager.balanceOf(address(this), uint160(address(usdc)));
        if (backing < totalRevenue - totalClaimed + mintProceeds + amount) {
            revert InexactTransfer();
        }
        _recordRevenue(amount);
    }

    function pendingForToken(uint256 tokenId) public view returns (uint256) {
        if (tokenId == 0 || tokenId > MAX_SUPPLY) revert InvalidQuantity();
        return totalRevenue / MAX_SUPPLY - settledPerToken[tokenId];
    }

    function claim(uint256[] calldata tokenIds) external nonReentrant returns (uint256 amount) {
        if (tokenIds.length > MAX_SUPPLY) revert InvalidQuantity();
        for (uint256 index; index < tokenIds.length; ++index) {
            uint256 tokenId = tokenIds[index];
            if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
            _settle(msg.sender, tokenId);
        }
        amount = credits[msg.sender];
        if (amount == 0) revert NothingToClaim();
        credits[msg.sender] = 0;
        totalClaimed += amount;
        _redeemRevenue(amount);
        _pushExact(msg.sender, amount);
        emit RevenueClaimed(msg.sender, amount);
    }

    function claimMintProceeds() external nonReentrant {
        if (msg.sender != treasury) revert Unauthorized();
        uint256 amount = mintProceeds;
        if (amount == 0) revert NothingToClaim();
        mintProceeds = 0;
        _pushExact(treasury, amount);
        emit MintProceedsClaimed(treasury, amount);
    }

    /// @dev Only an initiated pull claim may redeem this receiver's ERC-6909 backing.
    /// Mint proceeds are never used to pay revenue claims.
    function _redeemRevenue(uint256 amount) private {
        uint256 cash = usdc.balanceOf(address(this));
        if (cash < mintProceeds) revert InexactTransfer();
        uint256 revenueCash = cash - mintProceeds;
        if (revenueCash >= amount) return;
        withdrawing = true;
        poolManager.unlock(abi.encode(amount - revenueCash));
        withdrawing = false;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !withdrawing) revert Unauthorized();
        uint256 amount = abi.decode(data, (uint256));
        uint256 beforeBalance = usdc.balanceOf(address(this));
        poolManager.burn(address(this), uint160(address(usdc)), amount);
        poolManager.take(Currency.wrap(address(usdc)), address(this), amount);
        if (usdc.balanceOf(address(this)) != beforeBalance + amount) revert InexactTransfer();
        return "";
    }

    function _recordRevenue(uint256 amount) private {
        totalRevenue += amount;
        emit RevenueDeposited(msg.sender, amount, totalRevenue);
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        address previousOwner = _ownerOf(tokenId);
        if (previousOwner != address(0)) _settle(previousOwner, tokenId);
        return super._update(to, tokenId, auth);
    }

    function _settle(address holder, uint256 tokenId) private {
        uint256 index = totalRevenue / MAX_SUPPLY;
        uint256 prior = settledPerToken[tokenId];
        if (index > prior) credits[holder] += index - prior;
        settledPerToken[tokenId] = index;
    }

    function _baseURI() internal view override returns (string memory) {
        return metadataBase;
    }

    function _pullExact(address from, uint256 amount) private {
        uint256 beforeSender = usdc.balanceOf(from);
        uint256 beforeReceiver = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(from, address(this), amount);
        uint256 afterSender = usdc.balanceOf(from);
        uint256 afterReceiver = usdc.balanceOf(address(this));
        if (
            afterSender > beforeSender || beforeSender - afterSender != amount
                || afterReceiver < beforeReceiver || afterReceiver - beforeReceiver != amount
        ) revert InexactTransfer();
    }

    function _pushExact(address to, uint256 amount) private {
        uint256 beforeSender = usdc.balanceOf(address(this));
        uint256 beforeReceiver = usdc.balanceOf(to);
        usdc.safeTransfer(to, amount);
        uint256 afterSender = usdc.balanceOf(address(this));
        uint256 afterReceiver = usdc.balanceOf(to);
        if (
            afterSender > beforeSender || beforeSender - afterSender != amount
                || afterReceiver < beforeReceiver || afterReceiver - beforeReceiver != amount
        ) revert InexactTransfer();
    }
}
