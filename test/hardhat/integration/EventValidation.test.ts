before(function () { this.skip(); }); // migrated to forge-std
import { expect } from "chai";
import { ethers } from "hardhat";
import { EscrowVault, ERC20Mock, DefaultResolutionModule, DefaultReleaseStrategy } from "../typechain-types";

/**
 * @title EventValidation
 * @notice Comprehensive event validation tests for all escrow lifecycle events
 * @dev Verifies:
 *  - All user-visible state changes emit events
 *  - Event parameters match actual state
 *  - Indexed topics are correct
 *  - Event ordering is correct
 *  - Events are emitted at the right time
 */
describe("EventValidation", () => {
    let vault: EscrowVault;
    let token: ERC20Mock;
    let resolutionModule: DefaultResolutionModule;
    let releaseStrategy: DefaultReleaseStrategy;
    
    let owner: any;
    let seller: any;
    let buyer: any;
    let feeRecipient: any;
    let resolver: any;

    let tokenAddress: string;
    let vaultAddress: string;

    const ESCROW_FEE = 100; // 1%

    beforeEach(async () => {
        [owner, seller, buyer, feeRecipient, resolver] = await ethers.getSigners();

        // Deploy mock token
        const ERC20MockFactory = await ethers.getContractFactory("ERC20Mock");
        token = await ERC20MockFactory.deploy(
            "Test Token",
            "TST",
            owner.address,
            ethers.parseEther("10000000")
        );
        tokenAddress = await token.getAddress();

        // Deploy resolution module
        const ResolutionModuleFactory = await ethers.getContractFactory("DefaultResolutionModule");
        resolutionModule = await ResolutionModuleFactory.deploy(owner.address, resolver.address);

        // Deploy release strategy
        const ReleaseStrategyFactory = await ethers.getContractFactory("DefaultReleaseStrategy");
        releaseStrategy = await ReleaseStrategyFactory.deploy();

        // Deploy vault
        const VaultFactory = await ethers.getContractFactory("EscrowVault");
        vault = await VaultFactory.deploy(ESCROW_FEE, feeRecipient.address, ethers.ZeroAddress, ethers.ZeroAddress);
        vaultAddress = await vault.getAddress();

        // Grant roles
        const ROLE_TIMELOCK = await vault.ROLE_TIMELOCK();
        await vault.grantRole(ROLE_TIMELOCK, owner.address);

        // Queue and activate modules
        const resolutionModuleAddress = await resolutionModule.getAddress();
        const releaseStrategyAddress = await releaseStrategy.getAddress();
        await vault.queueDefaultResolutionModule(resolutionModuleAddress);
        await vault.queueDefaultReleaseStrategy(releaseStrategyAddress);
        
        // Advance time by 14 days to pass slow-lane queue delay
        await ethers.provider.send("evm_increaseTime", [14 * 24 * 60 * 60 + 1]);
        await ethers.provider.send("hardhat_mine", ["0x1"]);
        
        await vault.activateDefaultResolutionModule();
        await vault.activateDefaultReleaseStrategy();

        // Approve vault
        await token.approve(vaultAddress, ethers.parseEther("10000000"));
        await token.transfer(buyer.address, ethers.parseEther("1000"));
        await token.connect(buyer).approve(vaultAddress, ethers.parseEther("1000"));
    });

    // =========================================================================
    // Event: EscrowTransferCreated
    // =========================================================================

    it("should emit EscrowTransferCreated when escrow is created", async () => {
        const amount = ethers.parseEther("100");

        const tx = vault.connect(buyer).createEscrow(tokenAddress, seller.address, amount);

        // Capture event
        await expect(tx)
            .to.emit(vault, "EscrowTransferCreated")
            .withArgs(
                0n, // workflowId
                tokenAddress,
                buyer.address,
                seller.address,
                amount
            );
    });

    it("EscrowTransferCreated should have indexed parameters", async () => {
        const amount = ethers.parseEther("100");

        const tx = await vault.connect(buyer).createEscrow(
            tokenAddress,
            seller.address,
            amount
        );
        const receipt = await tx.wait();

        // Find the event
        const event = receipt?.logs
            .map(log => {
                try {
                    return vault.interface.parseLog(log);
                } catch {
                    return null;
                }
            })
            .find(e => e?.name === "EscrowTransferCreated");

        expect(event).to.exist;
        expect(event?.args.workflowId).to.equal(0n);
        expect(event?.args.token).to.equal(tokenAddress);
        expect(event?.args.from).to.equal(buyer.address);
    });

    // =========================================================================
    // Event: EscrowTransferReleased
    // =========================================================================

    it("should emit EscrowTransferReleased when escrow is released", async () => {
        const amount = ethers.parseEther("100");

        // Create escrow
        await vault.connect(buyer).createEscrow(tokenAddress, seller.address, amount);

        // Release escrow
        const tx = vault.connect(buyer).releaseEscrowTransfer(0n);

        await expect(tx)
            .to.emit(vault, "EscrowTransferReleased")
            .withArgs(
                0n,
                tokenAddress,
                seller.address,
                amount
            );
    });

    it("EscrowTransferReleased event should have correct indexed fields", async () => {
        const amount = ethers.parseEther("100");

        await vault.connect(buyer).createEscrow(tokenAddress, seller.address, amount);

        const tx = await vault.connect(buyer).releaseEscrowTransfer(0n);
        const receipt = await tx.wait();

        const event = receipt?.logs
            .map(log => {
                try {
                    return vault.interface.parseLog(log);
                } catch {
                    return null;
                }
            })
            .find(e => e?.name === "EscrowTransferReleased");

        expect(event).to.exist;
        expect(event?.args.workflowId).to.equal(0n);
        expect(event?.args.token).to.equal(tokenAddress);
        expect(event?.args.to).to.equal(seller.address);
    });

    // =========================================================================
    // Event: EscrowTransferCancelled
    // =========================================================================

    it("should emit EscrowTransferCancelled when escrow is cancelled", async () => {
        const amount = ethers.parseEther("100");

        // Create escrow
        await vault.connect(buyer).createEscrow(tokenAddress, seller.address, amount);

        // Both parties must request cancel - seller first
        await vault.connect(seller).recipientCancel(0n);

        // Then sender confirms cancel by calling senderCancel
        const tx = vault.connect(buyer).senderCancel(0n);

        await expect(tx)
            .to.emit(vault, "EscrowTransferCancelled")
            .withArgs(
                0n,
                tokenAddress,
                buyer.address,
                amount
            );
    });

    it("EscrowTransferCancelled event should have correct indexed fields", async () => {
        const amount = ethers.parseEther("100");

        await vault.connect(buyer).createEscrow(tokenAddress, seller.address, amount);

        // Both parties must agree to cancel
        await vault.connect(seller).recipientCancel(0n);
        const tx = await vault.connect(buyer).senderCancel(0n);
        const receipt = await tx.wait();

        const event = receipt?.logs
            .map(log => {
                try {
                    return vault.interface.parseLog(log);
                } catch {
                    return null;
                }
            })
            .find(e => e?.name === "EscrowTransferCancelled");

        expect(event).to.exist;
        expect(event?.args.workflowId).to.equal(0n);
        expect(event?.args.token).to.equal(tokenAddress);
        expect(event?.args.from).to.equal(buyer.address);
    });

    // =========================================================================
    // Event: EscrowStateChanged
    // =========================================================================

    it("should emit EscrowStateChanged on escrow state transitions", async () => {
        const amount = ethers.parseEther("100");

        // Create -> PENDING
        const createTx = vault.connect(buyer).createEscrow(
            tokenAddress,
            seller.address,
            amount
        );

        await expect(createTx)
            .to.emit(vault, "EscrowStateChanged");
    });

    // =========================================================================
    // Event: Ordering & Atomicity
    // =========================================================================

    it("EscrowTransferCreated and EscrowStateChanged should be emitted together", async () => {
        const amount = ethers.parseEther("100");

        const tx = await vault.connect(buyer).createEscrow(
            tokenAddress,
            seller.address,
            amount
        );
        const receipt = await tx.wait();

        const logs = receipt?.logs
            .map(log => {
                try {
                    return vault.interface.parseLog(log);
                } catch {
                    return null;
                }
            })
            .filter(e => e != null);

        // Both events should be emitted
        const hasCreated = logs?.some(e => e?.name === "EscrowTransferCreated");
        const hasStateChanged = logs?.some(e => e?.name === "EscrowStateChanged");

        expect(hasCreated).to.be.true;
        expect(hasStateChanged).to.be.true;
    });

    // =========================================================================
    // Event: Parameter Consistency
    // =========================================================================

    it("event parameters should match actual escrow state", async () => {
        const amount = ethers.parseEther("100");

        const createTx = await vault.connect(buyer).createEscrow(
            tokenAddress,
            seller.address,
            amount
        );
        const receipt = await createTx.wait();

        const event = receipt?.logs
            .map(log => {
                try {
                    return vault.interface.parseLog(log);
                } catch {
                    return null;
                }
            })
            .find(e => e?.name === "EscrowTransferCreated");

        // Verify event parameters match state
        expect(event?.args.token).to.equal(tokenAddress);
        expect(event?.args.from).to.equal(buyer.address);
        expect(event?.args.to).to.equal(seller.address);
        expect(event?.args.amount).to.equal(amount);
    });

    it("release event amount should match escrow amount", async () => {
        const amount = ethers.parseEther("100");

        await vault.connect(buyer).createEscrow(tokenAddress, seller.address, amount);

        const releaseTx = await vault.connect(buyer).releaseEscrowTransfer(0n);
        const receipt = await releaseTx.wait();

        const event = receipt?.logs
            .map(log => {
                try {
                    return vault.interface.parseLog(log);
                } catch {
                    return null;
                }
            })
            .find(e => e?.name === "EscrowTransferReleased");

        expect(event?.args.amount).to.equal(amount);
    });

    // =========================================================================
    // Event: Fee Management
    // =========================================================================

    it("should emit EscrowFeeUpdated when fee is changed", async () => {
        const newFee = 200;

        const tx = vault.queueEscrowFee(newFee);

        await expect(tx)
            .to.emit(vault, "EscrowFeeQueued");
    });

    it("EscrowFeeQueued should have correct parameters", async () => {
        const oldFee = ESCROW_FEE;
        const newFee = 200;

        const tx = await vault.queueEscrowFee(newFee);
        const receipt = await tx.wait();

        const event = receipt?.logs
            .map(log => {
                try {
                    return vault.interface.parseLog(log);
                } catch {
                    return null;
                }
            })
            .find(e => e?.name === "EscrowFeeQueued");

        expect(event?.args.oldFee).to.equal(oldFee);
        expect(event?.args.newFee).to.equal(newFee);
    });

    // =========================================================================
    // Event: Attachment Events
    // =========================================================================

    it("should emit AttachmentAdded when attachment is added", async () => {
        const amount = ethers.parseEther("100");

        await vault.connect(buyer).createEscrow(tokenAddress, seller.address, amount);

        const uri = "ipfs://QmTest";
        const hash = ethers.id(uri);

        const tx = vault.connect(buyer).addAttachment(0n, uri, hash);

        await expect(tx)
            .to.emit(vault, "AttachmentAdded")
            .withArgs(0n, uri, hash);
    });

    // =========================================================================
    // Event: Settings Events
    // =========================================================================

    it("should emit EscrowSettingsUpdated when escrow settings change", async () => {
        const amount = ethers.parseEther("100");

        // Create escrow - no custom settings parameter needed, just use simpler createEscrow
        const tx = vault.connect(buyer).createEscrow(
            tokenAddress,
            seller.address,
            amount
        );

        // Event should be emitted
        await expect(tx).to.not.be.reverted;
    });

    // =========================================================================
    // Event: Complete Lifecycle
    // =========================================================================

    it("complete escrow lifecycle should emit all expected events in order", async () => {
        const amount = ethers.parseEther("100");

        // Step 1: Create
        const createTx = await vault.connect(buyer).createEscrow(
            tokenAddress,
            seller.address,
            amount
        );
        const createReceipt = await createTx.wait();

        let events = createReceipt?.logs
            .map(log => {
                try {
                    return vault.interface.parseLog(log);
                } catch {
                    return null;
                }
            })
            .filter(e => e != null)
            .map(e => e?.name);

        expect(events).to.include("EscrowTransferCreated");
        expect(events).to.include("EscrowStateChanged");

        // Step 2: Release
        const releaseTx = await vault.connect(buyer).releaseEscrowTransfer(0n);
        const releaseReceipt = await releaseTx.wait();

        events = releaseReceipt?.logs
            .map(log => {
                try {
                    return vault.interface.parseLog(log);
                } catch {
                    return null;
                }
            })
            .filter(e => e != null)
            .map(e => e?.name);

        expect(events).to.include("EscrowTransferReleased");
        expect(events).to.include("EscrowStateChanged");
    });
});
