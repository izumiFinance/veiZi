
const { BigNumber } = require("bignumber.js");
const { expect } = require("chai");
const hardhat = require('hardhat');
const { ethers } = require("hardhat");;

async function getToken() {

  // deploy token
  const tokenFactory = await ethers.getContractFactory("TestToken")
  token = await tokenFactory.deploy('a', 'a', 18);
  await token.deployed();
  return token;
}

function decimalToUnDecimalStr(num) {
    return new BigNumber(num).times(10 ** 18).toFixed(0);
}

function stringDiv(a, b) {
    let an = new BigNumber(a);
    an = an.minus(an.mod(b));
    return an.div(b).toFixed(0, 3);
}

function stringMul(a, b) {
    let an = new BigNumber(a);
    an = an.times(b);
    return an.toFixed(0, 3);
}

function stringMinus(a, b) {
    let an = new BigNumber(a);
    an = an.minus(b);
    return an.toFixed(0, 3);
}

function stringAdd(a, b) {
    let an = new BigNumber(a);
    an = an.plus(b);
    return an.toFixed(0, 3);
}

function getBiasAndSlopeStr(amount, lockTime, MAXTIME) {
    const slope = stringDiv(amount, MAXTIME);
    const bias = stringMul(slope, lockTime);
    return {slope, bias};
}

function getBiasAndSlope(amount, lockTime, MAXTIME) {
    return getBiasAndSlopeStr(String(amount), String(lockTime), String(MAXTIME));
}

async function getNftLocked(veiZi, nftId) {
    const nftLocked = await veiZi.nftLocked(nftId);
    return {amount: Number(nftLocked.amount.toString()), end: Number(nftLocked.end.toString())};
}

async function getPoint(veiZi, epoch) {
    const point = await veiZi.pointHistory(epoch);
    return {bias: point.bias.toString(), slope: point.slope.toString(), blk: Number(point.blk.toString())};
}

async function waitUntilJustBefore(destBlockNumber) {
    let currentBlockNumber = await ethers.provider.getBlockNumber();
    while (currentBlockNumber < destBlockNumber - 1) {
        await ethers.provider.send('evm_mine');
        currentBlockNumber = await ethers.provider.getBlockNumber();
    }
    return currentBlockNumber;
}

describe("test uniswap price oracle", function () {

    var signer, tester;
    var iZi;
    var veiZi;

    beforeEach(async function() {
      
        [signer, tester] = await ethers.getSigners();

        // a fake weth
        const tokenFactory = await ethers.getContractFactory("TestToken");
        iZi = await tokenFactory.deploy('iZi', 'iZi', 18);

        
        const veiZiFactory = await ethers.getContractFactory("veiZi");
        const secondsOfWeek = 7 * 24 * 3600;
        const secondsPerBlockX64 = BigNumber(secondsOfWeek / 14).times(BigNumber(2).pow(64)).toFixed(0);
        veiZi = await veiZiFactory.deploy(iZi.address, secondsPerBlockX64, {
            provider: signer.address,
            accRewardPerShare: 0,
            rewardPerBlock: '100000000000000000',
            lastTouchBlock: 0,
            startBlock: 0,
            endBlock: 1000
        });

        await iZi.connect(tester).approve(veiZi.address, decimalToUnDecimalStr(100000000));
        await iZi.mint(tester.address, decimalToUnDecimalStr(100000000));
        
    });
    
    it("check point", async function () {
        let currentBlockNumber = await ethers.provider.getBlockNumber();
        console.log('current block number: ', currentBlockNumber);
        const MAXTIME = Number((await veiZi.MAXTIME()).toString());
        currentBlockNumber = await ethers.provider.getBlockNumber();

        const WEEK = Number((await veiZi.WEEK()).toString());
        console.log('max time: ', MAXTIME);
        console.log('week time: ', WEEK);
        
        // lock1
        const startTime1 = WEEK + Math.round(WEEK / 7);
        currentBlockNumber = await waitUntilJustBefore(startTime1);
        console.log('start time: ', startTime1);
        console.log('current bn: ', currentBlockNumber);
        const unlockTime1 = 20 * WEEK;
        const iZiAmount1 = decimalToUnDecimalStr(10);
        await veiZi.connect(tester).createLock(iZiAmount1, unlockTime1);

        const segment1 = getBiasAndSlope(iZiAmount1, unlockTime1 - startTime1, MAXTIME);
        console.log('segment1: ', segment1);
        const point1 = await getPoint(veiZi, 1);
        console.log('point1: ', point1);

        expect(point1.bias).to.equal(segment1.bias);
        expect(point1.slope).to.equal(segment1.slope);
        expect(point1.blk).to.equal(startTime1);

        const currentPoint = {...segment1};

        // lock2
        const startTime2 = WEEK + Math.round(WEEK / 7 * 6);
        currentBlockNumber = await waitUntilJustBefore(startTime2);
        const unlockTime2 = 25 * WEEK;
        const iZiAmount2 = decimalToUnDecimalStr(5);
        await veiZi.connect(tester).createLock(iZiAmount2, unlockTime2);
        const segment2 = getBiasAndSlope(iZiAmount2, unlockTime2 - startTime2, MAXTIME);
        // compute current point
        currentPoint.bias = stringMinus(currentPoint.bias, stringMul(String(startTime2-startTime1), currentPoint.slope));
        currentPoint.bias = stringAdd(currentPoint.bias, segment2.bias);
        currentPoint.slope = stringAdd(currentPoint.slope, segment2.slope);

        const point2 = await getPoint(veiZi, 2);
        expect(point2.bias).to.equal(currentPoint.bias);
        expect(point2.slope).to.equal(currentPoint.slope);
        expect(point2.blk).to.equal(startTime2);

        // lock3
        const startTime3 = WEEK * 6 + Math.round(WEEK / 7 * 3);
        currentBlockNumber = await waitUntilJustBefore(startTime3);
        const unlockTime3 = 30 * WEEK;
        const iZiAmount3 = decimalToUnDecimalStr(7);
        await veiZi.connect(tester).createLock(iZiAmount3, unlockTime3);
        const segment3 = getBiasAndSlope(iZiAmount3, unlockTime3 - startTime3, MAXTIME);
        // compute current point
        currentPoint.bias = stringMinus(currentPoint.bias, stringMul(String(startTime3-startTime2), currentPoint.slope));
        currentPoint.bias = stringAdd(currentPoint.bias, segment3.bias);
        currentPoint.slope = stringAdd(currentPoint.slope, segment3.slope);
        
        const point3 = await getPoint(veiZi, 3);
        expect(point3.bias).to.equal(currentPoint.bias);
        expect(point3.slope).to.equal(currentPoint.slope);
        expect(point3.blk).to.equal(startTime3);

        console.log('bias at 3: ', currentPoint.bias);

        // lock4
        const startTime4 = WEEK * 8 + Math.round(WEEK / 7 * 2);
        currentBlockNumber = await waitUntilJustBefore(startTime4);
        const unlockTime4 = 10 * WEEK;
        const iZiAmount4 = decimalToUnDecimalStr(30);
        await veiZi.connect(tester).createLock(iZiAmount4, unlockTime4);
        const segment4 = getBiasAndSlope(iZiAmount4, unlockTime4 - startTime4, MAXTIME);
        
        currentPoint.bias = stringMinus(currentPoint.bias, stringMul(String(startTime4-startTime3), currentPoint.slope));
        currentPoint.bias = stringAdd(currentPoint.bias, segment4.bias);
        currentPoint.slope = stringAdd(currentPoint.slope, segment4.slope);

        const point4 = await getPoint(veiZi, 4);
        expect(point4.bias).to.equal(currentPoint.bias);
        expect(point4.slope).to.equal(currentPoint.slope);
        expect(point4.blk).to.equal(startTime4);

        // lock5
        const startTime5 = WEEK * 8 + Math.round(WEEK / 7 * 3);
        currentBlockNumber = await waitUntilJustBefore(startTime5);
        const unlockTime5 = 10 * WEEK;
        const iZiAmount5 = decimalToUnDecimalStr(23);
        await veiZi.connect(tester).createLock(iZiAmount5, unlockTime5);
        const segment5 = getBiasAndSlope(iZiAmount5, unlockTime5 - startTime5, MAXTIME);
        
        currentPoint.bias = stringMinus(currentPoint.bias, stringMul(String(startTime5-startTime4), currentPoint.slope));
        currentPoint.bias = stringAdd(currentPoint.bias, segment5.bias);
        currentPoint.slope = stringAdd(currentPoint.slope, segment5.slope);

        const point5 = await getPoint(veiZi, 5);
        expect(point5.bias).to.equal(currentPoint.bias);
        expect(point5.slope).to.equal(currentPoint.slope);
        expect(point5.blk).to.equal(startTime5);


        // lock6
        const startTime6 = WEEK * 8 + Math.round(WEEK / 7 * 4);
        currentBlockNumber = await waitUntilJustBefore(startTime6);
        const unlockTime6 = 11 * WEEK;
        const iZiAmount6 = decimalToUnDecimalStr(92);
        await veiZi.connect(tester).createLock(iZiAmount6, unlockTime6);
        const segment6 = getBiasAndSlope(iZiAmount6, unlockTime6 - startTime6, MAXTIME);
        
        currentPoint.bias = stringMinus(currentPoint.bias, stringMul(String(startTime6-startTime5), currentPoint.slope));
        currentPoint.bias = stringAdd(currentPoint.bias, segment6.bias);
        currentPoint.slope = stringAdd(currentPoint.slope, segment6.slope);

        const point6 = await getPoint(veiZi, 6);
        expect(point6.bias).to.equal(currentPoint.bias);
        expect(point6.slope).to.equal(currentPoint.slope);
        expect(point6.blk).to.equal(startTime6);

        // lock7
        const startTime7 = WEEK * 8 + Math.round(WEEK / 7 * 5);
        currentBlockNumber = await waitUntilJustBefore(startTime7);
        const unlockTime7 = 11 * WEEK;
        const iZiAmount7 = decimalToUnDecimalStr(18);
        await veiZi.connect(tester).createLock(iZiAmount7, unlockTime7);
        const segment7 = getBiasAndSlope(iZiAmount7, unlockTime7 - startTime7, MAXTIME);
        
        currentPoint.bias = stringMinus(currentPoint.bias, stringMul(String(startTime7-startTime6), currentPoint.slope));
        currentPoint.bias = stringAdd(currentPoint.bias, segment7.bias);
        currentPoint.slope = stringAdd(currentPoint.slope, segment7.slope);

        const point7 = await getPoint(veiZi, 7);
        expect(point7.bias).to.equal(currentPoint.bias);
        expect(point7.slope).to.equal(currentPoint.slope);
        expect(point7.blk).to.equal(startTime7);

        // lock8
        const startTime8 = WEEK * 8 + Math.round(WEEK / 7 * 6);
        currentBlockNumber = await waitUntilJustBefore(startTime8);
        const unlockTime8 = 11 * WEEK;
        const iZiAmount8 = decimalToUnDecimalStr(12);
        await veiZi.connect(tester).createLock(iZiAmount8, unlockTime8);
        const segment8 = getBiasAndSlope(iZiAmount8, unlockTime8 - startTime8, MAXTIME);
        
        currentPoint.bias = stringMinus(currentPoint.bias, stringMul(String(startTime8-startTime7), currentPoint.slope));
        currentPoint.bias = stringAdd(currentPoint.bias, segment8.bias);
        currentPoint.slope = stringAdd(currentPoint.slope, segment8.slope);

        const point8 = await getPoint(veiZi, 8);
        expect(point8.bias).to.equal(currentPoint.bias);
        expect(point8.slope).to.equal(currentPoint.slope);
        expect(point8.blk).to.equal(startTime8);

        // lock9
        const startTime9 = WEEK * 10;
        currentBlockNumber = await waitUntilJustBefore(startTime9);
        const unlockTime9 = WEEK * 35;
        const iZiAmount9 = decimalToUnDecimalStr(215);
        await veiZi.connect(tester).createLock(iZiAmount9, unlockTime9);
        const segment9 = getBiasAndSlope(iZiAmount9, unlockTime9 - startTime9, MAXTIME);
        
        currentPoint.bias = stringMinus(currentPoint.bias, stringMul(String(startTime9-startTime8), currentPoint.slope));
        currentPoint.slope = stringMinus(currentPoint.slope, segment4.slope);
        currentPoint.slope = stringMinus(currentPoint.slope, segment5.slope);
        currentPoint.bias = stringAdd(currentPoint.bias, segment9.bias);
        currentPoint.slope = stringAdd(currentPoint.slope, segment9.slope);

        const point9 = await getPoint(veiZi, 9);
        expect(point9.bias).to.equal(currentPoint.bias);
        expect(point9.slope).to.equal(currentPoint.slope);
        expect(point9.blk).to.equal(startTime9);

        // lock10
        const startTime10 = WEEK * 10 + Math.round(WEEK / 7 * 2);
        currentBlockNumber = await waitUntilJustBefore(startTime10);
        const unlockTime10 = WEEK * 25;
        const iZiAmount10 = decimalToUnDecimalStr(11);
        await veiZi.connect(tester).createLock(iZiAmount10, unlockTime10);
        const segment10 = getBiasAndSlope(iZiAmount10, unlockTime10 - startTime10, MAXTIME);
        
        currentPoint.bias = stringMinus(currentPoint.bias, stringMul(String(startTime10-startTime9), currentPoint.slope));
        currentPoint.bias = stringAdd(currentPoint.bias, segment10.bias);
        currentPoint.slope = stringAdd(currentPoint.slope, segment10.slope);

        const point10 = await getPoint(veiZi, 10);
        expect(point10.bias).to.equal(currentPoint.bias);
        expect(point10.slope).to.equal(currentPoint.slope);
        expect(point10.blk).to.equal(startTime10);

        // lock11
        const startTime11 = WEEK * 10 + Math.round(WEEK / 7 * 3);
        currentBlockNumber = await waitUntilJustBefore(startTime11);
        const unlockTime11 = WEEK * 20;
        const iZiAmount11 = decimalToUnDecimalStr(115);
        await veiZi.connect(tester).createLock(iZiAmount11, unlockTime11);
        const segment11 = getBiasAndSlope(iZiAmount11, unlockTime11 - startTime11, MAXTIME);
        
        currentPoint.bias = stringMinus(currentPoint.bias, stringMul(String(startTime11-startTime10), currentPoint.slope));
        currentPoint.bias = stringAdd(currentPoint.bias, segment11.bias);
        currentPoint.slope = stringAdd(currentPoint.slope, segment11.slope);

        const point11 = await getPoint(veiZi, 11);
        expect(point11.bias).to.equal(currentPoint.bias);
        expect(point11.slope).to.equal(currentPoint.slope);
        expect(point11.blk).to.equal(startTime11);

        // check point
        let checkPoint = WEEK * 11;
        currentPoint.bias = stringMinus(currentPoint.bias, stringMul(String(checkPoint - startTime11), currentPoint.slope));
        currentPoint.slope = stringMinus(currentPoint.slope, segment6.slope);
        currentPoint.slope = stringMinus(currentPoint.slope, segment7.slope);
        currentPoint.slope = stringMinus(currentPoint.slope, segment8.slope);
        
        // currentBlockNumber = await waitUntilJustBefore(checkPoint);
        // await veiZi.connect(tester).checkPoint();

        // const point12 = await getPoint(veiZi, 12);
        // expect(point12.bias).to.equal(currentPoint.bias);
        // expect(point12.slope).to.equal(currentPoint.slope);
        // expect(point12.blk).to.equal(checkPoint);

        // lock12
        const startTime12 = WEEK * 11 + Math.round(WEEK / 7 * 1);
        currentBlockNumber = await waitUntilJustBefore(startTime12);
        const unlockTime12 = WEEK * 20;
        const iZiAmount12 = decimalToUnDecimalStr(51);
        await veiZi.connect(tester).createLock(iZiAmount12, unlockTime12);
        const segment12 = getBiasAndSlope(iZiAmount12, unlockTime12 - startTime12, MAXTIME);
        
        currentPoint.bias = stringMinus(currentPoint.bias, stringMul(String(startTime12-checkPoint), currentPoint.slope));
        currentPoint.bias = stringAdd(currentPoint.bias, segment12.bias);
        currentPoint.slope = stringAdd(currentPoint.slope, segment12.slope);

        const point12 = await getPoint(veiZi, 12);
        expect(point12.bias).to.equal(currentPoint.bias);
        expect(point12.slope).to.equal(currentPoint.slope);
        expect(point12.blk).to.equal(startTime12);

        // lock13
        const startTime13 = WEEK * 11 + Math.round(WEEK / 7 * 2);
        currentBlockNumber = await waitUntilJustBefore(startTime13);
        const unlockTime13 = WEEK * 30;
        const iZiAmount13 = decimalToUnDecimalStr(16);
        await veiZi.connect(tester).createLock(iZiAmount13, unlockTime13);
        const segment13 = getBiasAndSlope(iZiAmount13, unlockTime13 - startTime13, MAXTIME);
        
        currentPoint.bias = stringMinus(currentPoint.bias, stringMul(String(startTime13-startTime12), currentPoint.slope));
        currentPoint.bias = stringAdd(currentPoint.bias, segment13.bias);
        currentPoint.slope = stringAdd(currentPoint.slope, segment13.slope);

        const point13 = await getPoint(veiZi, 13);
        expect(point13.bias).to.equal(currentPoint.bias);
        expect(point13.slope).to.equal(currentPoint.slope);
        expect(point13.blk).to.equal(startTime13);


        // lock14
        const startTime14 = WEEK * 11 + Math.round(WEEK / 7 * 3);
        currentBlockNumber = await waitUntilJustBefore(startTime14);
        const unlockTime14 = WEEK * 25;
        const iZiAmount14 = decimalToUnDecimalStr(6);
        await veiZi.connect(tester).createLock(iZiAmount14, unlockTime14);
        const segment14 = getBiasAndSlope(iZiAmount14, unlockTime14 - startTime14, MAXTIME);
        
        currentPoint.bias = stringMinus(currentPoint.bias, stringMul(String(startTime14-startTime13), currentPoint.slope));
        currentPoint.bias = stringAdd(currentPoint.bias, segment14.bias);
        currentPoint.slope = stringAdd(currentPoint.slope, segment14.slope);

        const point14 = await getPoint(veiZi, 14);
        expect(point14.bias).to.equal(currentPoint.bias);
        expect(point14.slope).to.equal(currentPoint.slope);
        expect(point14.blk).to.equal(startTime14);


        // check point
        const checkPoint20 = WEEK * 20;
        currentPoint.bias = stringMinus(currentPoint.bias, stringMul(String(checkPoint20 - startTime14), currentPoint.slope));
        currentPoint.slope = stringMinus(currentPoint.slope, segment12.slope);
        currentPoint.slope = stringMinus(currentPoint.slope, segment11.slope);
        currentPoint.slope = stringMinus(currentPoint.slope, segment1.slope);

        // currentBlockNumber = await waitUntilJustBefore(checkPoint20);
        // await veiZi.connect(tester).checkPoint();

        // const point15 = await getPoint(veiZi, 15);
        // expect(point15.bias).to.equal(currentPoint.bias);
        // expect(point15.slope).to.equal(currentPoint.slope);
        // expect(point15.blk).to.equal(checkPoint20);

        // check point
        const checkPoint25 = WEEK * 25;
        currentPoint.bias = stringMinus(currentPoint.bias, stringMul(String(checkPoint25 - checkPoint20), currentPoint.slope));
        currentPoint.slope = stringMinus(currentPoint.slope, segment14.slope);
        currentPoint.slope = stringMinus(currentPoint.slope, segment10.slope);
        currentPoint.slope = stringMinus(currentPoint.slope, segment2.slope);

        // currentBlockNumber = await waitUntilJustBefore(checkPoint25);
        // await veiZi.connect(tester).checkPoint();

        // const pointAt25 = await getPoint(veiZi, 15);
        // expect(pointAt25.bias).to.equal(currentPoint.bias);
        // expect(pointAt25.slope).to.equal(currentPoint.slope);
        // expect(pointAt25.blk).to.equal(checkPoint25);

        // check point
        const checkPoint30 = WEEK * 30;
        currentPoint.bias = stringMinus(currentPoint.bias, stringMul(String(checkPoint30 - checkPoint25), currentPoint.slope));
        currentPoint.slope = stringMinus(currentPoint.slope, segment13.slope);
        currentPoint.slope = stringMinus(currentPoint.slope, segment3.slope);

        // check point
        const checkPoint32 = WEEK * 32;
        currentPoint.bias = stringMinus(currentPoint.bias, stringMul(String(checkPoint32 - checkPoint30), currentPoint.slope));
        
        currentBlockNumber = await waitUntilJustBefore(checkPoint32);
        await veiZi.connect(tester).checkPoint();

        const pointAt32 = await getPoint(veiZi, 15);
        expect(pointAt32.bias).to.equal(currentPoint.bias);
        expect(pointAt32.slope).to.equal(currentPoint.slope);
        expect(pointAt32.blk).to.equal(checkPoint32);

    });

});