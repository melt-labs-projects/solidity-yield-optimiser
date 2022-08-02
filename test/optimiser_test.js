const FarmOptimiser = artifacts.require('Optimiser');
const DelegateCompounder = artifacts.require('DelegateCompounder');
const FarmCompounder = artifacts.require('PancakeswapCompounder');
const FarmGate = artifacts.require('Gate');
const Token = artifacts.require('Token');
const Native = artifacts.require('WETH');
const Router = artifacts.require('DummyRouter');
const MasterChef = artifacts.require('DummyPancakeswapFarm');
const { expectRevert } = require('@openzeppelin/test-helpers');
const { assert } = require('chai');


// Helper for converting to wei
const toWei = (ether) => { return web3.utils.toWei(ether.toString(), 'ether'); }

// Helper for converting from wei
const fromWei = (wei) => { return web3.utils.fromWei(wei); }


contract('Optimiser Basic Tests', accounts => {

    let optimiser;
    let compounder;
    let gate;
    let plantation;

    // Tokens
    let cake;
    let rwt;
    let lp;
    let token0;
    let token1;

    // Define named accounts
    let owner = accounts[0]
    let vault = accounts[1]
    let accountA = accounts[2]
    let accountB = accounts[3]

    before(async () => {
        
        // Some useful amounts
        let TenBillion = toWei(10000000000)
        let OneBillion = toWei(1000000000)

        // Define some tokens
        cake = await Token.new(TenBillion)
        rwt = await Token.new(TenBillion)
        lp = await Token.new(TenBillion)
        token0 = await Token.new(TenBillion)
        token1 = await Token.new(TenBillion)
        native = await Native.new(TenBillion);

        // Define our dummy contracts
        plantation = await MasterChef.new([lp.address, lp.address], cake.address, false)
        router = await Router.new(lp.address, 1)

        // Define our contracts for testing
        optimiser = await FarmOptimiser.new(rwt.address, vault, toWei(50))
        delegate = await DelegateCompounder.new()
        compounder = await FarmCompounder.new(optimiser.address, plantation.address, rwt.address, vault, native.address, delegate.address)
        gate = await FarmGate.new(optimiser.address)

        // Transfer some rewards to the farm contracts
        await cake.transfer(plantation.address, OneBillion, { from: owner })
        await rwt.transfer(optimiser.address, OneBillion, { from: owner })

        // Send some lp funds to users
        await lp.transfer(accountA, toWei(100), { from: owner })
        await lp.transfer(accountB, toWei(100), { from: owner })

        // Allow farm to use lp funds
        await lp.increaseAllowance(optimiser.address, TenBillion, { from: accountA });
        await lp.increaseAllowance(optimiser.address, TenBillion, { from: accountB });

        // Send funds to the router for swapping and liquidity
        await cake.transfer(router.address, OneBillion, { from: owner })
        await rwt.transfer(router.address, OneBillion, { from: owner })
        await lp.transfer(router.address, OneBillion, { from: owner })
        await token0.transfer(router.address, OneBillion, { from: owner })
        await token1.transfer(router.address, OneBillion, { from: owner })

    });

    it('should enable new farm', async () => {

        // Enable farm 0 in compounder
        await compounder.enableFarm(
            0, 
            [true, false, false],
            [lp.address, cake.address, token0.address, token1.address],
            [0, 0, 0],
            [cake.address, token0.address],
            [cake.address, token1.address],
            [
                [router.address],
                [cake.address, rwt.address]
            ],
            router.address
        )

        // Add compounder to optimiser
        await optimiser.addCompounder(compounder.address)

        // Enable farm 0 0 in optimiser
        await optimiser.enableFarm(0, 0, lp.address, 2, 0, 0)

        assert.equal(await compounder.isEnabled(0), true)
        assert.equal(await optimiser.isEnabled(0, 0), true)
        assert.equal(await optimiser.compounderCount(), 1)
        assert.equal(await optimiser.totalAllocPoints(), 2)
    });

    it('should deposit', async () => {
        balanceBefore = fromWei(await lp.balanceOf(accountA))
        await optimiser.deposit(0, 0, toWei(1), {from: accountA})
        balanceAfter = fromWei(await lp.balanceOf(accountA))

        assert.equal(await compounder.totalDeposited(0), toWei(1))
        assert.equal(balanceBefore - balanceAfter, 1)

        user = await optimiser.users(0, 0, accountA)
        assert.equal(user.pastRewards, 0)
        assert.equal(user.shares, toWei(1))
        assert.equal(user.rewardDebt, 0)
        pending = await optimiser.pending(0, 0, accountA)
        assert.equal(fromWei(pending), 0)

        farm = await optimiser.farms(0, 0)
        assert.equal(farm.totalShares, toWei(1))

    });

    it('should get user amount', async () => {
        assert.equal(await optimiser.getUserAmount(0, 0, accountA), toWei(1))
    })
    
    it('should get total deposited', async () => {
        assert.equal(await optimiser.getTotalDeposited(0, 0), toWei(1))
    })

    it('should deposit to address', async () => {
        balanceBefore = fromWei(await lp.balanceOf(accountB))
        await optimiser.depositTo(0, 0, toWei(1), accountA, {from: accountB})
        balanceAfter = fromWei(await lp.balanceOf(accountB))

        assert.equal(balanceBefore - balanceAfter, 1) // make sure user transferred the funds
        assert.equal(await compounder.totalDeposited(0), toWei(2))

        farm = await optimiser.farms(0, 0)
        assert.equal(farm.totalShares, toWei(2))

        user = await optimiser.users(0, 0, accountA)
        assert.equal(user.shares, toWei(2))
        
    });

    it('should withdraw', async () => {
        balanceBefore = fromWei(await lp.balanceOf(accountA))
        await optimiser.withdraw(0, 0, toWei(1), {from: accountA})
        balanceAfter = fromWei(await lp.balanceOf(accountA))

        assert.equal(balanceAfter - balanceBefore, 1) // make sure user got the funds back
        assert.equal(await compounder.totalDeposited(0), toWei(1))

        farm = await optimiser.farms(0, 0)
        assert.equal(farm.totalShares, toWei(1))

        user = await optimiser.users(0, 0, accountA)
        assert.equal(user.shares, toWei(1))

    });

    it('should revert withdraw from', async () => {
        expectRevert(optimiser.withdrawFrom(0, 0, toWei(1), accountA, {from: accountB}), "Not allowed to withdraw this amount.")

        // Should still revert if we don't allow enough
        await optimiser.approve(0, 0, toWei(0.5), accountB, {from: accountA})
        expectRevert(optimiser.withdrawFrom(0, 0, toWei(1), accountA, {from: accountB}), "Not allowed to withdraw this amount.")
    });

    it('should approve spender', async () => {
        allowanceBefore = await optimiser.allowances(0, 0, accountA, accountB)
        await optimiser.approve(0, 0, toWei(1), accountB, {from: accountA})
        allowanceAfter = await optimiser.allowances(0, 0, accountA, accountB)
        assert.equal(allowanceAfter - allowanceBefore, toWei(1))
    });

    it('should withdraw from address', async () => {
        balanceBefore = fromWei(await lp.balanceOf(accountB))
        await optimiser.withdrawFrom(0, 0, toWei(1), accountA, {from: accountB})
        balanceAfter = fromWei(await lp.balanceOf(accountB))

        assert.equal(balanceAfter - balanceBefore, 1)
        assert.equal(await compounder.totalDeposited(0), toWei(0))

        farm = await optimiser.farms(0, 0)
        assert.equal(farm.totalShares, 0)

        user = await optimiser.users(0, 0, accountA)
        assert.equal(user.rewardDebt, 0)
        assert.equal(user.shares, 0)
    });

    it('should harvest', async () => {
        pending = fromWei(await optimiser.pending(0, 0, accountA))
        balanceBefore = fromWei(await rwt.balanceOf(accountA))
        await optimiser.harvest(0, 0, {from: accountA})
        balanceAfter = fromWei(await rwt.balanceOf(accountA))
        assert.equal(pending, balanceAfter - balanceBefore)

        user = await optimiser.users(0, 0, accountA)
        assert.equal(user.pastRewards, 0)
        assert.equal(user.rewardDebt, 0)
        pending = await optimiser.pending(0, 0, accountA)
        assert.equal(fromWei(pending), 0)
    });

    it('should change withdraw fee', async () => {
        await optimiser.changeWithdrawFee(0, 0, 100)
        assert.equal((await optimiser.farms(0, 0)).withdrawFee, 100)
    });

    it('should revert change withdraw fee', async () => {
        expectRevert.unspecified(optimiser.changeWithdrawFee(0, 0, 20000))
    });

    it('should change deposit fee', async () => {
        await optimiser.changeDepositFee(0, 0, 100)
        assert.equal((await optimiser.farms(0, 0)).depositFee, 100)
    });

    it('should revert change deposit fee', async () => {
        expectRevert.unspecified(optimiser.changeDepositFee(0, 0, 20000))
    });

    it('should charge deposit and withdraw fees', async () => {
        await optimiser.changeWithdrawFee(0, 0, 5000)
        await optimiser.changeDepositFee(0, 0, 5000)

        vaultBefore = parseFloat(fromWei(await lp.balanceOf(vault)))
        await optimiser.deposit(0, 0, toWei(10), {from: accountA})
        vaultAfter = parseFloat(fromWei(await lp.balanceOf(vault)))
        assert.equal(vaultAfter - vaultBefore, 5)

        vaultBefore = parseFloat(fromWei(await lp.balanceOf(vault)))
        await optimiser.withdraw(0, 0, toWei(5), {from: accountA})
        vaultAfter = parseFloat(fromWei(await lp.balanceOf(vault)))
        assert.equal(vaultAfter - vaultBefore, 2.5)
    })

    it('should change allocation points', async () => {
        await optimiser.changeAllocPoints(0, 0, 1)
        assert.equal(await optimiser.totalAllocPoints(), 1)
        await optimiser.changeAllocPoints(0, 0, 500)
        assert.equal(await optimiser.totalAllocPoints(), 500)
    });

    it('should change rewards per block', async () => {
        await optimiser.changeRewardsPerBlock(toWei(100))
        assert.equal(await optimiser.rewardsPerBlock(), toWei(100))
    });

    it('should change vault', async () => {
        await optimiser.changeVault(accountA)
        assert.equal(await optimiser.vault(), accountA)
    });

    it('should get deposit token', async () => {
        assert.equal(await optimiser.depositToken(0, 0), lp.address)
    });

    it('should update', async () => {
        await optimiser.update(0, 0)
    })

    it('should get pending amount', async () => {
        await optimiser.pending(0, 0, accountA)
    });
    
    it('should revert owner methods when called by non-owner', async () => {
        expectRevert.unspecified(optimiser.enableFarm(0, 0, lp.address, 2, 0, 0, {from: accountA}))
        expectRevert.unspecified(optimiser.changeVault(accountA, {from: accountA}))
        expectRevert.unspecified(optimiser.changeRewardsPerBlock(toWei(100), {from: accountA}))
        expectRevert.unspecified(optimiser.changeAllocPoints(0, 0, 1, {from: accountA}))
        expectRevert.unspecified(optimiser.changeWithdrawFee(0, 0, 20000, {from: accountA}))
        expectRevert.unspecified(optimiser.changeDepositFee(0, 0, 20000, {from: accountA}))
    });

    it('should revert methods which require enabled', async () => {
        expectRevert(optimiser.update(1, 1), "This farm is not enabled.");
        expectRevert(optimiser.deposit(1, 1, toWei(1)), "This farm is not enabled.")
        expectRevert(optimiser.withdraw(1, 1, toWei(1)), "This farm is not enabled.")
        expectRevert(optimiser.harvest(1, 1), "This farm is not enabled.")
        expectRevert(optimiser.changeAllocPoints(1, 1, 1), "This farm is not enabled.")
        expectRevert(optimiser.changeWithdrawFee(1, 1, 5000), "This farm is not enabled.")
        expectRevert(optimiser.changeDepositFee(1, 1, 5000), "This farm is not enabled.")
    })

    it('should pause farm', async () => {
        await optimiser.changePaused(0, 0, true)
        farm = await optimiser.farms(0, 0)
        assert.equal(farm.paused, true)
    });

    it('should revert deposit when farm paused', async () => {
        expectRevert(optimiser.deposit(0, 0, toWei(1), {from: accountA}), "Farm is paused.")
    });

    it('should unpause farm', async () => {
        await optimiser.changePaused(0, 0, false)
        farm = await optimiser.farms(0, 0)
        assert.equal(farm.paused, false)
    });

    it('should not update rewards when paused', async () => {
        await optimiser.deposit(0, 0, toWei(1), {from: accountA})
        await optimiser.changePaused(0, 0, true)

        farmBefore = await optimiser.farms(0, 0)
        await optimiser.update(0, 0)
        farmAfter = await optimiser.farms(0, 0)

        assert.equal(fromWei(farmBefore.accRewardsPerShare), fromWei(farmAfter.accRewardsPerShare))
        await optimiser.changePaused(0, 0, false)
    });

    it('should pause contract', async () => {
        await optimiser.pause()
        assert.equal(await optimiser.paused(), true)
    });

    it('should revert deposit when contract paused', async () => {
        expectRevert(optimiser.deposit(0, 0, toWei(1), {from: accountA}), "Pausable: paused")
    });

    it('should unpause contract', async () => {
        await optimiser.unpause()
        assert.equal(await optimiser.paused(), false)
    });

    it('should not update rewards when paused', async () => {
        await optimiser.deposit(0, 0, toWei(1), {from: accountA})
        await optimiser.pause()

        farmBefore = await optimiser.farms(0, 0)
        await optimiser.update(0, 0)
        farmAfter = await optimiser.farms(0, 0)

        assert.equal(fromWei(farmBefore.accRewardsPerShare), fromWei(farmAfter.accRewardsPerShare))
    });

})

contract('Optimiser Rewards Tests', accounts => {

    let optimiser;
    let compounder;
    let gate;
    let plantation;

    // Tokens
    let cake;
    let rwt;
    let lp;
    let token0;
    let token1;

    // Define named accounts
    let owner = accounts[0]
    let vault = accounts[1]
    let accountA = accounts[2]
    let accountB = accounts[3]

    before(async () => {
        
        // Some useful amounts
        let TenBillion = toWei(10000000000)
        let OneBillion = toWei(1000000000)

        // Define some tokens
        cake = await Token.new(TenBillion)
        rwt = await Token.new(TenBillion)
        lp = await Token.new(TenBillion)
        token0 = await Token.new(TenBillion)
        token1 = await Token.new(TenBillion)
        native = await Native.new(TenBillion);

        // Define our dummy contracts
        plantation = await MasterChef.new([lp.address, lp.address], cake.address, false)
        router = await Router.new(lp.address, 1)

        // Define our contracts for testing
        optimiser = await FarmOptimiser.new(rwt.address, vault, toWei(50))
        delegate = await DelegateCompounder.new()
        compounder = await FarmCompounder.new(optimiser.address, plantation.address, rwt.address, vault, native.address, delegate.address)
        gate = await FarmGate.new(optimiser.address)

        // Transfer some rewards to the farm contracts
        await cake.transfer(plantation.address, OneBillion, { from: owner })
        await rwt.transfer(optimiser.address, OneBillion, { from: owner })

        // Send some lp funds to users
        await lp.transfer(accountA, toWei(100), { from: owner })
        await lp.transfer(accountB, toWei(100), { from: owner })

        // Allow farm to use lp funds
        await lp.increaseAllowance(optimiser.address, TenBillion, { from: accountA });
        await lp.increaseAllowance(optimiser.address, TenBillion, { from: accountB });

        // Send funds to the router for swapping and liquidity
        await cake.transfer(router.address, OneBillion, { from: owner })
        await rwt.transfer(router.address, OneBillion, { from: owner })
        await lp.transfer(router.address, OneBillion, { from: owner })
        await token0.transfer(router.address, OneBillion, { from: owner })
        await token1.transfer(router.address, OneBillion, { from: owner })

        // Enable farm 0 in compounder
        await compounder.enableFarm(
            0, 
            [true, false, false],
            [lp.address, cake.address, token0.address, token1.address],
            [0, 0, 0],
            [cake.address, token0.address],
            [cake.address, token1.address],
            [
                [router.address],
                [cake.address, rwt.address]
            ],
            router.address
        )

        // Add compounder to optimiser
        await optimiser.addCompounder(compounder.address)

        // Enable farm 0 0 in optimiser
        await optimiser.enableFarm(0, 0, lp.address, 2, 0, 0)

    })

    it('should calculate pending correctly', async () => {

        await optimiser.deposit(0, 0, toWei(1), {from: accountA})
        assert.equal(await optimiser.pending(0, 0, accountA), 0)

        await optimiser.deposit(0, 0, toWei(1), {from: accountA})
        assert.equal(await optimiser.pending(0, 0, accountA), toWei(50))

        await optimiser.update(0, 0)
        await optimiser.update(0, 0)
        
        assert.equal(await optimiser.pending(0, 0, accountA), toWei(150))

        await optimiser.deposit(0, 0, toWei(2), {from: accountB})
        assert.equal(await optimiser.pending(0, 0, accountA), toWei(200))
        assert.equal(await optimiser.pending(0, 0, accountB), toWei(0))

        await optimiser.update(0, 0)
        assert.equal(await optimiser.pending(0, 0, accountA), toWei(225))
        assert.equal(await optimiser.pending(0, 0, accountB), toWei(25))

        await optimiser.withdraw(0, 0, toWei(2), {from: accountA})
        assert.equal(await optimiser.pending(0, 0, accountA), toWei(250))
        assert.equal(await optimiser.pending(0, 0, accountB), toWei(50))

        await optimiser.update(0, 0)
        assert.equal(await optimiser.pending(0, 0, accountA), toWei(250))
        assert.equal(await optimiser.pending(0, 0, accountB), toWei(100))

        await optimiser.update(0, 0)
        assert.equal(await optimiser.pending(0, 0, accountB), toWei(150))

        await optimiser.withdraw(0, 0, toWei(2), {from: accountB})
        assert.equal(await optimiser.pending(0, 0, accountA), toWei(250))
        assert.equal(await optimiser.pending(0, 0, accountB), toWei(200))

    });

})

contract('Optimiser Shares Tests', accounts => {

    let optimiser;
    let compounder;
    let gate;
    let plantation;

    // Tokens
    let cake;
    let rwt;
    let lp;
    let token0;
    let token1;

    // Define named accounts
    let owner = accounts[0]
    let vault = accounts[1]
    let accountA = accounts[2]
    let accountB = accounts[3]
    let accountC = accounts[4]

    before(async () => {
        
        // Some useful amounts
        let TenBillion = toWei(10000000000)
        let OneBillion = toWei(1000000000)

        // Define some tokens
        cake = await Token.new(TenBillion)
        rwt = await Token.new(TenBillion)
        lp = await Token.new(TenBillion)
        token0 = await Token.new(TenBillion)
        token1 = await Token.new(TenBillion)
        native = await Native.new(TenBillion);

        // Define our dummy contracts
        plantation = await MasterChef.new([lp.address, lp.address], cake.address, false)
        router = await Router.new(lp.address, 1)

        // Define our contracts for testing
        optimiser = await FarmOptimiser.new(rwt.address, vault, 0)
        delegate = await DelegateCompounder.new()
        compounder = await FarmCompounder.new(optimiser.address, plantation.address, rwt.address, vault, native.address, delegate.address)
        gate = await FarmGate.new(optimiser.address)

        // Transfer some rewards to the farm contracts
        await cake.transfer(plantation.address, OneBillion, { from: owner })
        await rwt.transfer(optimiser.address, OneBillion, { from: owner })

        // Send some lp funds to users
        await lp.transfer(accountA, toWei(10000), { from: owner })
        await lp.transfer(accountB, toWei(10000), { from: owner })
        await lp.transfer(accountC, toWei(10000), { from: owner })

        // Allow farm to use lp funds
        await lp.increaseAllowance(optimiser.address, TenBillion, { from: accountA });
        await lp.increaseAllowance(optimiser.address, TenBillion, { from: accountB });
        await lp.increaseAllowance(optimiser.address, TenBillion, { from: accountC });

        // Send funds to the router for swapping and liquidity
        await cake.transfer(router.address, OneBillion, { from: owner })
        await rwt.transfer(router.address, OneBillion, { from: owner })
        await lp.transfer(router.address, OneBillion, { from: owner })
        await token0.transfer(router.address, OneBillion, { from: owner })
        await token1.transfer(router.address, OneBillion, { from: owner })

        // Enable farm 0 in compounder
        await compounder.enableFarm(
            0, 
            [true, false, false],
            [lp.address, cake.address, token0.address, token1.address],
            [0, 0, 0],
            [cake.address, token0.address],
            [cake.address, token1.address],
            [
                [router.address],
                [cake.address, rwt.address]
            ],
            router.address
        )

        await compounder.enableFarm(
            1, 
            [true, true, false],
            [lp.address, cake.address, token0.address, token1.address],
            [0, 0, 0],
            [cake.address, token0.address],
            [cake.address, token1.address],
            [
                [router.address],
                [cake.address, rwt.address]
            ],
            router.address
        )

        // Add compounder to optimiser
        await optimiser.addCompounder(compounder.address)

        // Enable farm 0 0 in optimiser
        await optimiser.enableFarm(0, 0, lp.address, 0, 5000, 5000)
        await optimiser.enableFarm(0, 1, lp.address, 0, 5000, 5000)

    })

    it('should calculate shares correctly', async () => {
        let i = 0

        await optimiser.deposit(0, i, toWei(10), {from: accountA})
        userA = await optimiser.users(0, i, accountA)

        // User deposited 10 and should now have 5 due to 50% deposit fee
        assert.equal(fromWei(userA.shares), 5)

        // First user should own the entire amount
        total = await optimiser.getTotalDeposited(0, i)
        userAmount = await optimiser.getUserAmount(0, i, accountA)
        assert.equal(fromWei(total), fromWei(userAmount))

        // First user should still own the total after a compound
        await compounder.compound(i);
        total = await optimiser.getTotalDeposited(0, i)
        userAmount = fromWei(await optimiser.getUserAmount(0, i, accountA))
        assert.equal(fromWei(total), userAmount)
        assert.equal(fromWei(total), 6) // compounding added 1 LP
        
        await optimiser.withdraw(0, i, toWei(userAmount/2), {from: accountA})

        userA = await optimiser.users(0, i, accountA)
        assert.equal(fromWei(userA.shares), 2.5)
        assert.equal(fromWei(await optimiser.getUserAmount(0, i, accountA)), 3)

        await optimiser.deposit(0, i, toWei(6), {from: accountB})
        userB = await optimiser.users(0, i, accountB)
        assert.equal(fromWei(userB.shares), 2.5)

        await compounder.compound(i);
        total = fromWei(await optimiser.getTotalDeposited(0, i))
        assert.equal(total, 7)

        userAmountA = fromWei(await optimiser.getUserAmount(0, i, accountA))
        assert.equal(userAmountA, 3.5)

        userAmountB = fromWei(await optimiser.getUserAmount(0, i, accountB))
        assert.equal(userAmountB, 3.5)

        await optimiser.deposit(0, i, toWei(693 * 2), {from: accountC})
        userC = await optimiser.users(0, i, accountC)
        assert.equal(fromWei(userC.shares), 495)

        assert.equal(fromWei(await optimiser.getUserAmount(0, i, accountA)), 3.5)
        assert.equal(fromWei(await optimiser.getUserAmount(0, i, accountB)), 3.5)
        assert.equal(fromWei(await optimiser.getUserAmount(0, i, accountC)), 693)

        await optimiser.withdraw(0, i, toWei(3.5), {from: accountA})
        await optimiser.withdraw(0, i, toWei(3.5), {from: accountB})

        total = fromWei(await optimiser.getTotalDeposited(0, i))
        userAmount = fromWei(await optimiser.getUserAmount(0, i, accountC))
        assert.equal(total, userAmount)

        await compounder.compound(i);
        total = fromWei(await optimiser.getTotalDeposited(0, i))
        userAmount = fromWei(await optimiser.getUserAmount(0, i, accountC))
        assert.equal(total, userAmount)
        
        assert.equal(fromWei(await optimiser.getUserAmount(0, i, accountC)), 694)
        balanceBefore = fromWei(await lp.balanceOf(accountC))
        await optimiser.withdraw(0, i, toWei(694), {from: accountC})
        balanceAfter = fromWei(await lp.balanceOf(accountC))

        assert.equal(balanceAfter - balanceBefore, 694 / 2)

    });

    it('should calculate shares correctly with compoundOnInteraction', async () => {
        let i = 1

        await optimiser.deposit(0, i, toWei(10), {from: accountA})
        userA = await optimiser.users(0, i, accountA)

        // User deposited 10 and should now have 5 due to 50% deposit fee
        assert.equal(fromWei(userA.shares), 5)

        // First user should own the entire amount
        total = await optimiser.getTotalDeposited(0, i)
        userAmount = await optimiser.getUserAmount(0, i, accountA)
        assert.equal(fromWei(total), fromWei(userAmount))

        // First user should still own the total after a compound
        await compounder.compound(i);
        total = await optimiser.getTotalDeposited(0, i)
        userAmount = fromWei(await optimiser.getUserAmount(0, i, accountA))
        assert.equal(fromWei(total), userAmount)
        assert.equal(fromWei(total), 6) // compounding added 1 LP
        
        balanceBefore = parseFloat(fromWei(await lp.balanceOf(accountA)))
        await optimiser.withdraw(0, i, toWei(userAmount/2), {from: accountA})
        balanceAfter = parseFloat(fromWei(await lp.balanceOf(accountA)))
        assert.equal(balanceAfter - balanceBefore, 1.75)

        userA = await optimiser.users(0, i, accountA)
        assert.equal(fromWei(userA.shares), 2.5)
        assert.equal(fromWei(await optimiser.getUserAmount(0, i, accountA)), 3.5)

        await optimiser.deposit(0, i, toWei(27), {from: accountB})
        userB = await optimiser.users(0, i, accountB)
        assert.equal(fromWei(userB.shares), 7.5)
        userAmountB = fromWei(await optimiser.getUserAmount(0, i, accountB))
        assert.equal(userAmountB, 13.5)

        await compounder.compound(i);
        total = fromWei(await optimiser.getTotalDeposited(0, i))
        assert.equal(total, 19)

        userAmountA = fromWei(await optimiser.getUserAmount(0, i, accountA))
        assert.equal(userAmountA, 4.75)

        userAmountB = fromWei(await optimiser.getUserAmount(0, i, accountB))
        assert.equal(userAmountB, 14.25)

        await optimiser.deposit(0, i, toWei(180 * 2), {from: accountC})
        userC = await optimiser.users(0, i, accountC)
        assert.equal(fromWei(userC.shares), 90)

        assert.equal(fromWei(await optimiser.getUserAmount(0, i, accountA)), 5)
        assert.equal(fromWei(await optimiser.getUserAmount(0, i, accountB)), 15)
        assert.equal(fromWei(await optimiser.getUserAmount(0, i, accountC)), 180)

        await optimiser.withdraw(0, i, toWei(5), {from: accountA})
        userA = await optimiser.users(0, i, accountA)
        assert.equal(fromWei(userA.shares), 0)

        userAmountB = parseFloat(fromWei(await optimiser.getUserAmount(0, i, accountB)))
        assert.closeTo(userAmountB, 15.075, 0.000001)

        await optimiser.withdraw(0, i, await optimiser.getUserAmount(0, i, accountB), {from: accountB})
        userB = await optimiser.users(0, i, accountB)
        assert.closeTo(parseFloat(fromWei(userB.shares)), 0, 0.000001)

        userAmountC = parseFloat(fromWei(await optimiser.getUserAmount(0, i, accountC)))
        assert.closeTo(userAmountC, 180.9 + (90/97.5), 0.000001)

        total = parseFloat(fromWei(await optimiser.getTotalDeposited(0, i)))
        userAmount = parseFloat(fromWei(await optimiser.getUserAmount(0, i, accountC)))
        assert.closeTo(total, userAmount, 0.000001)

        await compounder.compound(i);
        total = parseFloat(fromWei(await optimiser.getTotalDeposited(0, i)))
        userAmount = parseFloat(fromWei(await optimiser.getUserAmount(0, i, accountC)))
        assert.closeTo(total, userAmount, 0.000001)

        assert.closeTo(parseFloat(fromWei(await optimiser.getUserAmount(0, i, accountC))), 180.9 + (90/97.5) + 1, 0.000001)

        balanceBefore = parseFloat(fromWei(await lp.balanceOf(accountC)))
        await optimiser.withdraw(0, i, await optimiser.getUserAmount(0, i, accountC), {from: accountC})
        balanceAfter = parseFloat(fromWei(await lp.balanceOf(accountC)))

        assert.closeTo(balanceAfter - balanceBefore, (180.9 + (90/97.5) + 2) / 2, 0.000001)

        assert.equal(fromWei(await optimiser.getTotalDeposited(0, 1)), 0)
        farm = await optimiser.farms(0, 0)
        assert.equal(fromWei(farm.totalShares), 0)

    });

})

