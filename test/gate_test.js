const FarmOptimiser = artifacts.require('Optimiser');
const FarmCompounder = artifacts.require('PancakeswapCompounder');
const DelegateCompounder = artifacts.require('DelegateCompounder');
const FarmGate = artifacts.require('Gate');
const Token = artifacts.require('Token');
const LPToken = artifacts.require('LPToken');
const Native = artifacts.require('WETH');
const Router = artifacts.require('DummyRouter');
const MasterChef = artifacts.require('DummyPancakeswapFarm');
const { expectRevert } = require('@openzeppelin/test-helpers');
const { assert } = require('chai');


// Helper for converting to wei
const toWei = (ether) => { return web3.utils.toWei(ether.toString(), 'ether'); }

// Helper for converting from wei
const fromWei = (wei) => { return web3.utils.fromWei(wei); }


contract('Gate Tests', accounts => {

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
        token0 = await Token.new(TenBillion)
        token1 = await Token.new(TenBillion)
        lp = await LPToken.new(TenBillion, token0.address, token1.address)
        native = await Native.new(TenBillion);

        // Define our dummy contracts
        plantation = await MasterChef.new([lp.address, cake.address], cake.address, false)
        router = await Router.new(lp.address, 1)
        otherRouter = await Router.new(lp.address, 1)

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
        await token0.transfer(accountA, toWei(100), { from: owner })
        await token1.transfer(accountA, toWei(100), { from: owner })
        await rwt.transfer(accountA, toWei(100), { from: owner })
        await cake.transfer(accountA, toWei(100), { from: owner })

        // Allow farm to use lp funds
        await token0.increaseAllowance(gate.address, TenBillion, { from: accountA });
        await token1.increaseAllowance(gate.address, TenBillion, { from: accountA });
        await lp.increaseAllowance(gate.address, TenBillion, { from: accountA });
        await rwt.increaseAllowance(gate.address, TenBillion, { from: accountA });
        await cake.increaseAllowance(gate.address, TenBillion, { from: accountA });

        // Send funds to the router for swapping and liquidity
        await cake.transfer(router.address, OneBillion, { from: owner })
        await rwt.transfer(router.address, OneBillion, { from: owner })
        await lp.transfer(router.address, OneBillion, { from: owner })
        await token0.transfer(router.address, OneBillion, { from: owner })
        await token1.transfer(router.address, OneBillion, { from: owner })

        await cake.transfer(otherRouter.address, OneBillion, { from: owner })
        await token0.transfer(otherRouter.address, OneBillion, { from: owner })
        await token1.transfer(otherRouter.address, OneBillion, { from: owner })

        // Enable farm 0 in compounder
        await compounder.enableFarm(
            0, 
            [true, false, false],
            [lp.address, cake.address, token0.address, token1.address],
            [100, 100, 0],
            [cake.address, token0.address],
            [cake.address, token1.address],
            [
                [otherRouter.address, router.address],
                [cake.address, token0.address, token1.address],
                [token1.address, rwt.address]
            ],
            router.address    
        )

        // Add compounder to optimiser
        await optimiser.addCompounder(compounder.address)

        // Enable farm 0 1 in optimiser
        await optimiser.enableFarm(0, 0, lp.address, 2, 0, 0)

        // Enable farm 1 in compounder
        await compounder.enableFarm(
            1, 
            [false, false, false],
            [cake.address, cake.address],
            [0, 0, 0],
            [],
            [],
            [
                [otherRouter.address, router.address],
                [cake.address, token1.address],
                [token1.address, rwt.address]
            ],
            router.address    
        )

        // Enable farm 0 0 in optimiser
        await optimiser.enableFarm(0, 1, cake.address, 2, 0, 0)

    });

    it('should deposit token0', async () => {
        balanceBefore = parseFloat(fromWei(await token0.balanceOf(accountA)))
        await gate.deposit(
            1,
            0, 
            0, 
            toWei(2), 
            [
                [router.address, otherRouter.address], 
                [token0.address, cake.address], [cake.address, token1.address]
            ], 
            [],
            router.address,
            { from: accountA }
        )
        balanceAfter = parseFloat(fromWei(await token0.balanceOf(accountA)))
        assert.equal(balanceBefore - balanceAfter, 2)
        await compounder.compound(0)
    });

    it('should deposit token1', async () => {
        balanceBefore = parseFloat(fromWei(await token1.balanceOf(accountA)))
        await gate.deposit(
            1,
            0, 
            0, 
            toWei(2), 
            [
                [router.address, otherRouter.address], 
                [token1.address, cake.address], [cake.address, token0.address]
            ], 
            [],
            router.address,
            { from: accountA }
        )
        balanceAfter = parseFloat(fromWei(await token1.balanceOf(accountA)))
        assert.equal(balanceBefore - balanceAfter, 2)
        await compounder.compound(0)
        
    });
    
    it('should deposit desired token', async () => {
        balanceBefore = parseFloat(fromWei(await rwt.balanceOf(accountA)))
        await gate.deposit(
            2,
            0, 
            0, 
            toWei(2), 
            [
                [router.address, otherRouter.address], 
                [rwt.address, cake.address], [cake.address, token0.address]
            ], 
            [
                [router.address, otherRouter.address], 
                [rwt.address, cake.address], [cake.address, token1.address]
            ],
            router.address,
            { from: accountA }
        )
        balanceAfter = parseFloat(fromWei(await rwt.balanceOf(accountA)))
        assert.equal(balanceBefore - balanceAfter, 2)
        await compounder.compound(0)
        
    });

    it('should deposit desired token to non-LP farm', async () => {
        balanceBefore = parseFloat(fromWei(await rwt.balanceOf(accountA)))
        await gate.deposit(
            0,
            0, 
            1, 
            toWei(2), 
            [
                [router.address], 
                [rwt.address, cake.address]
            ], 
            [],
            router.address,
            { from: accountA }
        )
        balanceAfter = parseFloat(fromWei(await rwt.balanceOf(accountA)))
        assert.equal(balanceBefore - balanceAfter, 2)

    });
    
    it('should withdraw both tokens', async () => {
        balanceBeforeToken0 = parseFloat(fromWei(await token0.balanceOf(accountA)))
        balanceBeforeToken1 = parseFloat(fromWei(await token1.balanceOf(accountA)))

        await optimiser.approve(0, 0, toWei(1), gate.address, {from: accountA})
        await gate.withdraw(
            3,
            0, 
            0, 
            toWei(1), 
            [], 
            [],
            router.address,
            { from: accountA }
        )
        balanceAfterToken0 = parseFloat(fromWei(await token0.balanceOf(accountA)))
        balanceAfterToken1 = parseFloat(fromWei(await token1.balanceOf(accountA)))

        assert.isAbove(balanceAfterToken0, balanceBeforeToken0)
        assert.isAbove(balanceAfterToken1, balanceBeforeToken1)

    });

    it('should withdraw token0', async () => {
        await optimiser.approve(0, 0, toWei(1), gate.address, {from: accountA})
        balance = parseFloat(fromWei(await token0.balanceOf(accountA)))
        await gate.withdraw(
            1,
            0, 
            0, 
            toWei(1), 
            [
                [router.address], 
                [token1.address, token0.address]
            ], 
            [],
            router.address,
            { from: accountA }
        )
        balanceAfter = parseFloat(fromWei(await token0.balanceOf(accountA)))
        assert.isAbove(balanceAfter, balanceBefore)
    });

    it('should withdraw token1', async () => {
        await optimiser.approve(0, 0, toWei(1), gate.address, {from: accountA})
        balance = parseFloat(fromWei(await token1.balanceOf(accountA)))
        await gate.withdraw(
            1,
            0, 
            0, 
            toWei(1), 
            [
                [router.address], 
                [token0.address, token1.address]
            ], 
            [],
            router.address,
            { from: accountA }
        )
        balanceAfter = parseFloat(fromWei(await token1.balanceOf(accountA)))
        assert.isAbove(balanceAfter, balanceBefore)

    });

    it('should withdraw desired token', async () => {

        await gate.deposit(
            1,
            0, 
            0, 
            toWei(1), 
            [
                [router.address, otherRouter.address], 
                [token1.address, cake.address], [cake.address, token0.address]
            ], 
            [],
            router.address,
            { from: accountA }
        )
    
        await optimiser.approve(0, 0, toWei(1), gate.address, {from: accountA})
        balance = parseFloat(fromWei(await cake.balanceOf(accountA)))
        await gate.withdraw(
            2,
            0, 
            0, 
            toWei(1), 
            [
                [otherRouter.address], 
                [token0.address, cake.address]
            ], 
            [
                [otherRouter.address], 
                [token1.address, cake.address]
            ], 
            router.address,
            { from: accountA }
        )
        balanceAfter = parseFloat(fromWei(await cake.balanceOf(accountA)))
        assert.isAbove(balanceAfter, balanceBefore)


    });

    it('should withdraw desired token from non-LP farm', async () => {
        await optimiser.approve(0, 1, toWei(1), gate.address, {from: accountA})
        balanceBefore = parseFloat(fromWei(await rwt.balanceOf(accountA)))
        await gate.withdraw(
            0,
            0, 
            1, 
            toWei(0.5), 
            [
                [router.address], 
                [cake.address, rwt.address]
            ], 
            [], 
            router.address,
            { from: accountA }
        )
        balanceAfter = parseFloat(fromWei(await rwt.balanceOf(accountA)))
        assert.isAbove(balanceAfter, balanceBefore)

    });

})