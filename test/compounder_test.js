const FarmOptimiser = artifacts.require('Optimiser');
const FarmCompounder = artifacts.require('PancakeswapCompounder');
const DelegateCompounder = artifacts.require('DelegateCompounder');
const FarmGate = artifacts.require('Gate');
const Token = artifacts.require('Token');
const Native = artifacts.require('WETH');
const Router = artifacts.require('DummyRouter');
const MasterChef = artifacts.require('DummyPancakeswapFarm');
const { expectRevert } = require('@openzeppelin/test-helpers');
const { assert } = require('chai');
const Web3 = require('web3');

// Helper for retrieving the blockNumber
const getBlockNumber = async () => {
    return await web3.eth.getBlockNumber();
}

// Helper for converting to wei
const toWei = (ether) => { return web3.utils.toWei(ether.toString(), 'ether'); }

// Helper for converting from wei
const fromWei = (wei) => { return web3.utils.fromWei(wei); }


contract('Compounder Tests', accounts => {

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

    let BURN_ADDRESS = "0x000000000000000000000000000000000000dEaD"

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
        delegate = await DelegateCompounder.new()
        compounder = await FarmCompounder.new(owner, plantation.address, rwt.address, vault, native.address, delegate.address)

        // Transfer some rewards to the farm contracts
        await cake.transfer(plantation.address, OneBillion, { from: owner })

        // Send some lp funds to users
        await lp.transfer(accountA, toWei(100), { from: owner })
        await lp.transfer(accountB, toWei(100), { from: owner })

        // Allow compounder to use lp funds
        await lp.increaseAllowance(compounder.address, TenBillion, { from: owner });

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

        // Enable farm 1 in compounder
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

    })

    it('should return correct farm addresses', async () => {
        farm = await compounder.farmAddresses(0)
        assert.equal(farm.depositToken, lp.address)
        assert.equal(farm.rewardToken, cake.address)
        assert.equal(farm.token0, token0.address)
        assert.equal(farm.token1, token1.address)
        assert.equal(farm.lpRouter, router.address)
        assert.equal(farm.rewardToToken0Path[0], cake.address)
        assert.equal(farm.rewardToToken0Path[1], token0.address)
        assert.equal(farm.rewardToToken1Path[0], cake.address)
        assert.equal(farm.rewardToToken1Path[1], token1.address)
        assert.equal(farm.rewardToRwtSwap[0][0], router.address)
        assert.equal(farm.rewardToRwtSwap[1][0], cake.address)
        assert.equal(farm.rewardToRwtSwap[1][1], rwt.address)
    })

    it('should return correct farm params', async () => {

        // Enable farm 2 in compounder
        await compounder.enableFarm(
            2, 
            [false, true, true],
            [cake.address, native.address],
            [1, 2, 3],
            [],
            [],
            [
                [router.address],
                [native.address, rwt.address]
            ],
            router.address
        )

        farm = await compounder.farmParams(2)
        assert.equal(farm.compoundOnInteraction, true)
        assert.equal(farm.rewardTokenIsDepositToken, false)
        assert.equal(farm.isLPFarm, false)
        assert.equal(farm.isRewardNative, true)
        assert.equal(farm.treasuryFee, 1)
        assert.equal(farm.buyBackRate, 2)
        assert.equal(farm.buyBackDelta, 3)

        // Enable farm 3 in compounder
        await compounder.enableFarm(
            3, 
            [true, false, false],
            [lp.address, lp.address, token0.address, token1.address],
            [2, 3, 1],
            [],
            [],
            [[]],
            router.address
        )

        farm = await compounder.farmParams(3)
        assert.equal(farm.compoundOnInteraction, false)
        assert.equal(farm.rewardTokenIsDepositToken, true)
        assert.equal(farm.isLPFarm, true)
        assert.equal(farm.isRewardNative, false)
        assert.equal(farm.treasuryFee, 2)
        assert.equal(farm.buyBackRate, 3)
        assert.equal(farm.buyBackDelta, 1)
    })

    it('should deposit without compound', async () => {
        balanceBefore = fromWei(await lp.balanceOf(owner))
        await compounder.deposit(0, toWei(1))
        balanceAfter = fromWei(await lp.balanceOf(owner))

        assert.equal(balanceBefore - balanceAfter, 1)
        assert.equal(await compounder.totalDeposited(0), toWei(1))
        
        // No rewards given since we didn't have anything staked.
        reserve = await compounder.reserves(0)
        assert.equal(fromWei(reserve.rewards), 0)
        assert.equal(fromWei(reserve.token0), 0)
        assert.equal(fromWei(reserve.token1), 0)

        await compounder.deposit(0, toWei(1))
        reserve = await compounder.reserves(0)
        assert.equal(fromWei(reserve.rewards), 10)
        assert.equal(fromWei(reserve.token0), 0)
        assert.equal(fromWei(reserve.token1), 0)
    
    });

    it('should return total deposited', async () => {
        assert.equal(await compounder.totalDeposited(0), toWei(2))    
    });

    it('should withdraw without compound', async () => {
        balanceBefore = fromWei(await lp.balanceOf(owner))
        await compounder.withdraw(0, toWei(2))
        balanceAfter = fromWei(await lp.balanceOf(owner))

        assert.equal(balanceAfter - balanceBefore, 2)
        assert.equal(await compounder.totalDeposited(0), 0)

        reserve = await compounder.reserves(0)
        assert.equal(fromWei(reserve.rewards), 20)
        assert.equal(fromWei(reserve.token0), 0)
        assert.equal(fromWei(reserve.token1), 0)

    });

    it('should deposit with compound', async () => {
        balanceBefore = fromWei(await lp.balanceOf(owner))
        await compounder.deposit(1, toWei(1))
        balanceAfter = fromWei(await lp.balanceOf(owner))

        assert.equal(balanceBefore - balanceAfter, 1)
        assert.equal(await compounder.totalDeposited(1), toWei(1))

        reserve = await compounder.reserves(1)
        assert.equal(fromWei(reserve.rewards), 0)
        assert.equal(fromWei(reserve.token0), 0)
        assert.equal(fromWei(reserve.token1), 0)
    
    });

    it('should withdraw with compound', async () => {
        balanceBefore = fromWei(await lp.balanceOf(owner))
        await compounder.withdraw(1, toWei(1), {from: owner, gas: 3000000})
        balanceAfter = fromWei(await lp.balanceOf(owner))

        assert.equal(balanceAfter - balanceBefore, 2)

        reserve = await compounder.reserves(1)
        assert.equal(fromWei(reserve.rewards), 0)

    });

    it('should compound', async () => {
        await compounder.deposit(0, toWei(1))

        depositedBefore = await compounder.totalDeposited(0)
        await compounder.compound(0, {from: owner, gas: 3000000})
        depositedAfter = await compounder.totalDeposited(0)

        // LP should have increase by 1
        assert.equal(fromWei(depositedAfter) - fromWei(depositedBefore), 1)

        depositedBefore = await compounder.totalDeposited(0)
        await compounder.compound(0, {from: owner, gas: 3000000})
        depositedAfter = await compounder.totalDeposited(0)

        // LP should have increase by 1
        assert.equal(fromWei(depositedAfter) - fromWei(depositedBefore), 1)
    })

    it('should change treasury', async () => {
        assert.equal((await compounder.globalInfo())._treasury, vault)
        await compounder.changeGlobalParams(accountA, BURN_ADDRESS, 9500)
        assert.equal((await compounder.globalInfo())._treasury, accountA)
        await compounder.changeGlobalParams(vault, BURN_ADDRESS, 9500)
        assert.equal((await compounder.globalInfo())._treasury, vault)
    })

    it('should change buyback address', async () => {
        assert.equal((await compounder.globalInfo())._buyBackAddress, BURN_ADDRESS)
        await compounder.changeGlobalParams(vault, accountA, 9500)
        assert.equal((await compounder.globalInfo())._buyBackAddress, accountA)
        await compounder.changeGlobalParams(vault, BURN_ADDRESS, 9500)
        assert.equal((await compounder.globalInfo())._buyBackAddress, BURN_ADDRESS)
    })

    it('should change fee params in set', async () => {
        assert.equal((await compounder.farmParams(0)).treasuryFee, 0)
        assert.equal((await compounder.farmParams(1)).treasuryFee, 0)
        assert.equal((await compounder.farmParams(0)).buyBackRate, 0)
        assert.equal((await compounder.farmParams(1)).buyBackRate, 0)
        await compounder.changeParamsInSet([1], 100, 100, true, 0)
        assert.equal((await compounder.farmParams(0)).treasuryFee, 0)
        assert.equal((await compounder.farmParams(1)).treasuryFee, 100)
        assert.equal((await compounder.farmParams(0)).buyBackRate, 0)
        assert.equal((await compounder.farmParams(1)).buyBackRate, 100)
        await compounder.changeParamsInSet([0, 1], 2500, 2500, true, 0)
        assert.equal((await compounder.farmParams(0)).treasuryFee, 2500)
        assert.equal((await compounder.farmParams(1)).treasuryFee, 2500)
        assert.equal((await compounder.farmParams(0)).buyBackRate, 2500)
        assert.equal((await compounder.farmParams(1)).buyBackRate, 2500)
    })

    it('should change compounds param in set', async () => {
        assert.equal((await compounder.farmParams(0)).compoundOnInteraction, true)
        assert.equal((await compounder.farmParams(1)).compoundOnInteraction, true)
        await compounder.changeParamsInSet([0, 1], 2500, 2500, true, 0)
        assert.equal((await compounder.farmParams(0)).compoundOnInteraction, true)
        assert.equal((await compounder.farmParams(1)).compoundOnInteraction, true)
        await compounder.changeParamsInSet([0, 1], 2500, 2500, false, 0)
        assert.equal((await compounder.farmParams(0)).compoundOnInteraction, false)
        assert.equal((await compounder.farmParams(1)).compoundOnInteraction, false)
        await compounder.changeParamsInSet([0], 2500, 2500, true, 0)
        assert.equal((await compounder.farmParams(0)).compoundOnInteraction, true)
        assert.equal((await compounder.farmParams(1)).compoundOnInteraction, false)
    })

    it('should change buy back delta in set', async () => {
        assert.equal((await compounder.farmParams(0)).buyBackDelta, 0)
        assert.equal((await compounder.farmParams(1)).buyBackDelta, 0)
        await compounder.changeParamsInSet([0, 1], 2500, 2500, true, 100)
        assert.equal((await compounder.farmParams(0)).buyBackDelta, 100)
        assert.equal((await compounder.farmParams(1)).buyBackDelta, 100)
        await compounder.changeParamsInSet([0, 1], 2500, 2500, true, 2000)
        assert.equal((await compounder.farmParams(0)).buyBackDelta, 2000)
        assert.equal((await compounder.farmParams(1)).buyBackDelta, 2000)
        await compounder.changeParamsInSet([1], 2500, 2500, true, 2)
        assert.equal((await compounder.farmParams(0)).buyBackDelta, 2000)
        assert.equal((await compounder.farmParams(1)).buyBackDelta, 2)
        await compounder.changeParamsInSet([0, 1], 2500, 2500, true, 0)
        assert.equal((await compounder.farmParams(0)).buyBackDelta, 0)
        assert.equal((await compounder.farmParams(1)).buyBackDelta, 0)
    })
    
    it('should charge treasury fees and buy back', async () => {
        deadrwtBefore = parseFloat(fromWei(await rwt.balanceOf(BURN_ADDRESS)))
        vaultCakeBefore = parseFloat(fromWei(await cake.balanceOf(vault)))
        await compounder.compound(0, {from: owner, gas: 3000000})
        deadrwtAfter = parseFloat(fromWei(await rwt.balanceOf(BURN_ADDRESS)))
        vaultCakeAfter = parseFloat(fromWei(await cake.balanceOf(vault)))
        assert.isAbove(vaultCakeAfter, vaultCakeBefore)
        assert.isAbove(deadrwtAfter, deadrwtBefore)
    })

    it('should add to burned total', async () => {
        deadrwtBefore = parseFloat(fromWei(await rwt.balanceOf(BURN_ADDRESS)))
        await compounder.compound(0, {from: owner, gas: 3000000})
        deadrwtAfter = parseFloat(fromWei(await rwt.balanceOf(BURN_ADDRESS)))
        assert.isAbove(deadrwtAfter - deadrwtBefore, 0)
    })

    it('should test manual buyback', async () => {
        await compounder.changeParamsInSet([0], 2500, 2500, true, 1000)

        deadrwtBefore = parseFloat(fromWei(await rwt.balanceOf(BURN_ADDRESS)))
        await compounder.compound(0, {from: owner, gas: 3000000})
        deadrwtAfter = parseFloat(fromWei(await rwt.balanceOf(BURN_ADDRESS)))
        assert.equal(deadrwtAfter - deadrwtBefore, 0)

        await compounder.changeParamsInSet([0], 2500, 2500, true, 0)

        deadrwtBefore = parseFloat(fromWei(await rwt.balanceOf(BURN_ADDRESS)))
        await compounder.buyBack(0)
        deadrwtAfter = parseFloat(fromWei(await rwt.balanceOf(BURN_ADDRESS)))
        assert.isAbove(deadrwtAfter, deadrwtBefore)
    })

    it('should check that buy back amount accumulates for different farms with same reward', async () => {
        await compounder.changeParamsInSet([0, 1], 2500, 2500, true, 10000)

        await compounder.deposit(0, toWei(1))
        buyBackAmountBefore = parseFloat(fromWei((await compounder.buyBacks(cake.address)).pending))
        await compounder.compound(0, {from: owner, gas: 3000000})
        buyBackAmountAfter = parseFloat(fromWei((await compounder.buyBacks(cake.address)).pending))
        buyBackDelta1 = buyBackAmountAfter - buyBackAmountBefore
        assert.isAbove(buyBackDelta1, 0)

        farm = await compounder.farmParams(1)
        assert.equal(farm.rewardTokenIsDepositToken, false)
        
        await compounder.deposit(1, toWei(1))
        buyBackAmountBefore = parseFloat(fromWei((await compounder.buyBacks(cake.address)).pending))
        await compounder.compound(1, {from: owner, gas: 3000000})
        buyBackAmountAfter = parseFloat(fromWei((await compounder.buyBacks(cake.address)).pending))
        buyBackDelta2 = buyBackAmountAfter - buyBackAmountBefore
        assert.isAbove(buyBackDelta2, 0)

        await compounder.buyBack(0)

        buyBackAmount = parseFloat(fromWei((await compounder.buyBacks(cake.address)).pending))
        assert.equal(buyBackAmount, 0)


        
    })

})

contract('Compounder Dust Test', accounts => {

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
        router = await Router.new(lp.address, 2)

        // Define our contracts for testing
        delegate = await DelegateCompounder.new()
        compounder = await FarmCompounder.new(owner, plantation.address, rwt.address, vault, native.address, delegate.address)

        // Transfer some rewards to the farm contracts
        await cake.transfer(plantation.address, OneBillion, { from: owner })

        // Send some lp funds to users
        await lp.transfer(accountA, toWei(100), { from: owner })
        await lp.transfer(accountB, toWei(100), { from: owner })

        // Allow compounder to use lp funds
        await lp.increaseAllowance(compounder.address, TenBillion, { from: owner });

        // Send funds to the router for swapping and liquidity
        await cake.transfer(router.address, OneBillion, { from: owner })
        await rwt.transfer(router.address, OneBillion, { from: owner })
        await lp.transfer(router.address, OneBillion, { from: owner })
        await token0.transfer(router.address, OneBillion, { from: owner })
        await token1.transfer(router.address, OneBillion, { from: owner })

        // Enable farm 1 in compounder
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

    })

    it('should convert dust to rewards', async () => {

        await compounder.deposit(1, toWei(10))

        totalBefore = parseFloat(fromWei(await compounder.totalDeposited(1)))
        await compounder.compound(1);
        totalAfter = parseFloat(fromWei(await compounder.totalDeposited(1)))
        assert.isAbove(totalAfter, totalBefore)

        reserve = await compounder.reserves(1);
        assert.isAbove(parseInt(fromWei(reserve.token0)), 0)
        assert.isAbove(parseInt(fromWei(reserve.token1)), 0)
        assert.equal(parseInt(fromWei(reserve.rewards)), 0)

        await compounder.convertDustToRewards(1);

        reserve = await compounder.reserves(1);
        assert.equal(parseInt(fromWei(reserve.token0)), 0)
        assert.equal(parseInt(fromWei(reserve.token1)), 0)
        assert.isAbove(parseInt(fromWei(reserve.rewards)), 0)

    })

})


contract('Compounder Native Token Test', accounts => {

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
        plantation = await MasterChef.new([lp.address, lp.address], native.address, true)
        router = await Router.new(lp.address, 2)

        // Define our contracts for testing
        delegate = await DelegateCompounder.new()
        compounder = await FarmCompounder.new(owner, plantation.address, rwt.address, vault, native.address, delegate.address)

        // Transfer some rewards to the farm contracts
        await native.transfer(plantation.address, OneBillion, { from: owner })
        await plantation.send(toWei(1), { from: owner })

        const web3 = new Web3("http://localhost:9545")
        //let balance = await web3.eth.getBalance(plantation.address);
        //console.log(balance);

        // Send some lp funds to users
        await lp.transfer(accountA, toWei(100), { from: owner })
        await lp.transfer(accountB, toWei(100), { from: owner })

        // Allow compounder to use lp funds
        await lp.increaseAllowance(compounder.address, TenBillion, { from: owner });

        // Send funds to the router for swapping and liquidity
        await cake.transfer(router.address, OneBillion, { from: owner })
        await rwt.transfer(router.address, OneBillion, { from: owner })
        await lp.transfer(router.address, OneBillion, { from: owner })
        await token0.transfer(router.address, OneBillion, { from: owner })
        await token1.transfer(router.address, OneBillion, { from: owner })
        await native.transfer(router.address, OneBillion, { from: owner })

        // Enable farm 1 in compounder
        await compounder.enableFarm(
            1, 
            [true, true, true],
            [lp.address, native.address, token0.address, token1.address],
            [0, 0, 0],
            [native.address, token0.address],
            [native.address, token1.address],
            [
                [router.address],
                [native.address, rwt.address]
            ],
            router.address
        )

    })

    it('should deposit, compound and convert dust to rewards for native token', async () => {

        await compounder.deposit(1, toWei(10))
        reserve = await compounder.reserves(1);
        assert.equal(fromWei(reserve.rewards), 0)

        totalBefore = parseFloat(fromWei(await compounder.totalDeposited(1)))
        await compounder.compound(1);
        totalAfter = parseFloat(fromWei(await compounder.totalDeposited(1)))
        assert.isAbove(totalAfter, totalBefore)

        reserve = await compounder.reserves(1);
        assert.equal(parseFloat(fromWei(reserve.rewards)), 0)
        assert.isAbove(parseFloat(fromWei(reserve.token0)), 0)
        assert.isAbove(parseFloat(fromWei(reserve.token1)), 0)

        await compounder.convertDustToRewards(1);

        reserve = await compounder.reserves(1);
        assert.equal(parseFloat(fromWei(reserve.token0)), 0)
        assert.equal(parseFloat(fromWei(reserve.token1)), 0)
        assert.isAbove(parseFloat(fromWei(reserve.rewards)), 0)

        await compounder.withdraw(1, toWei(10))

    })

})