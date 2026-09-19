// Firestore 安全規則測試（跑在 Firebase emulator 上，不會碰到任何線上專案）
//
// 執行方式（在 firestore-tests/ 內）：
//   npm install
//   npm test
//
// 測試重點是 issue #34 的兩個 collection：
//   - supply_items：共用型錄，沒有擁有者，只能改 pledgedQty
//   - pledges：有 userId，只有擁有者能改／刪
//
// 最關鍵的一條是「使用者能認領別人建立的物資」——那是加擁有者檢查最容易弄壞的地方。

import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, it } from 'node:test';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  deleteDoc,
  doc,
  getDoc,
  increment,
  serverTimestamp,
  setDoc,
  updateDoc,
} from 'firebase/firestore';

const ALICE = 'uid-alice';
const BOB = 'uid-bob';

let testEnv;

const seedItem = {
  name: '礦泉水',
  unit: '瓶',
  category: '食品飲水',
  neededQty: 500,
  pledgedQty: 0,
};

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-cares',
    firestore: {
      rules: readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8'),
    },
  });
});

after(async () => {
  await testEnv?.cleanup();
});

beforeEach(async () => {
  await testEnv.clearFirestore();
  // 以「繞過規則」的方式鋪底，模擬型錄已經被種子寫入、且 alice 已有一筆認領
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, 'supply_items/water'), seedItem);
    await setDoc(doc(db, 'pledges/pledge-alice'), {
      userId: ALICE,
      userName: 'Alice',
      itemId: 'water',
      itemName: '礦泉水',
      unit: '瓶',
      quantity: 10,
      status: 'pledged',
      pledgedAt: new Date(),
    });
  });
});

const dbFor = (uid) => testEnv.authenticatedContext(uid).firestore();
const anonDb = () => testEnv.unauthenticatedContext().firestore();

describe('supply_items', () => {
  it('登入用戶可讀', async () => {
    await assertSucceeds(getDoc(doc(dbFor(BOB), 'supply_items/water')));
  });

  it('未登入不可讀', async () => {
    await assertFails(getDoc(doc(anonDb(), 'supply_items/water')));
  });

  // ★ 迴歸測試：這是加擁有者檢查會弄壞的行為
  it('★ 使用者可以在「不是自己建立的」物資上累加 pledgedQty', async () => {
    await assertSucceeds(
      updateDoc(doc(dbFor(BOB), 'supply_items/water'), {
        pledgedQty: increment(5),
      }),
    );
  });

  it('未登入不可累加 pledgedQty', async () => {
    await assertFails(
      updateDoc(doc(anonDb(), 'supply_items/water'), { pledgedQty: increment(5) }),
    );
  });

  it('不可竄改 name', async () => {
    await assertFails(updateDoc(doc(dbFor(BOB), 'supply_items/water'), { name: '假資料' }));
  });

  it('不可竄改 neededQty', async () => {
    await assertFails(updateDoc(doc(dbFor(BOB), 'supply_items/water'), { neededQty: 0 }));
  });

  it('不可在改 pledgedQty 的同時夾帶其他欄位', async () => {
    await assertFails(
      updateDoc(doc(dbFor(BOB), 'supply_items/water'), {
        pledgedQty: increment(1),
        category: '衣物',
      }),
    );
  });

  it('不可新增未定義的欄位', async () => {
    await assertFails(updateDoc(doc(dbFor(BOB), 'supply_items/water'), { owner: BOB }));
  });

  it('pledgedQty 不可設為負數', async () => {
    await assertFails(updateDoc(doc(dbFor(BOB), 'supply_items/water'), { pledgedQty: -1 }));
  });

  it('pledgedQty 不可設為非整數', async () => {
    await assertFails(updateDoc(doc(dbFor(BOB), 'supply_items/water'), { pledgedQty: 'many' }));
  });

  it('任何人都不可刪除', async () => {
    await assertFails(deleteDoc(doc(dbFor(BOB), 'supply_items/water')));
    await assertFails(deleteDoc(doc(dbFor(ALICE), 'supply_items/water')));
  });

  it('種子寫入（欄位齊全、pledgedQty 為 0）可以建立', async () => {
    await assertSucceeds(setDoc(doc(dbFor(ALICE), 'supply_items/blanket'), {
      ...seedItem,
      name: '毛毯',
      unit: '條',
      category: '生活用品',
      neededQty: 150,
    }));
  });

  it('建立時夾帶多餘欄位會被擋下', async () => {
    await assertFails(setDoc(doc(dbFor(ALICE), 'supply_items/evil'), {
      ...seedItem,
      injected: 'x',
    }));
  });

  it('建立時 pledgedQty 不為 0 會被擋下', async () => {
    await assertFails(setDoc(doc(dbFor(ALICE), 'supply_items/evil'), {
      ...seedItem,
      pledgedQty: 9999,
    }));
  });

  it('建立時欄位型別錯誤會被擋下', async () => {
    await assertFails(setDoc(doc(dbFor(ALICE), 'supply_items/evil'), {
      ...seedItem,
      neededQty: '500',
    }));
  });

  it('建立時缺欄位會被擋下', async () => {
    await assertFails(setDoc(doc(dbFor(ALICE), 'supply_items/evil'), { name: '只有名字' }));
  });
});

describe('pledges', () => {
  const newPledge = (uid) => ({
    userId: uid,
    userName: 'Someone',
    itemId: 'water',
    itemName: '礦泉水',
    unit: '瓶',
    quantity: 3,
    status: 'pledged',
    pledgedAt: serverTimestamp(),
  });

  it('可以建立自己的認領', async () => {
    await assertSucceeds(setDoc(doc(dbFor(BOB), 'pledges/pledge-bob'), newPledge(BOB)));
  });

  it('不可冒用他人 userId 建立認領', async () => {
    await assertFails(setDoc(doc(dbFor(BOB), 'pledges/pledge-fake'), newPledge(ALICE)));
  });

  it('建立時夾帶多餘欄位會被擋下', async () => {
    await assertFails(
      setDoc(doc(dbFor(BOB), 'pledges/pledge-bob'), { ...newPledge(BOB), role: 'admin' }),
    );
  });

  it('建立時 quantity 必須為正整數', async () => {
    await assertFails(
      setDoc(doc(dbFor(BOB), 'pledges/pledge-bob'), { ...newPledge(BOB), quantity: 0 }),
    );
    await assertFails(
      setDoc(doc(dbFor(BOB), 'pledges/pledge-bob'), { ...newPledge(BOB), quantity: '3' }),
    );
  });

  it('擁有者可以修改自己的認領數量', async () => {
    await assertSucceeds(
      updateDoc(doc(dbFor(ALICE), 'pledges/pledge-alice'), {
        quantity: 20,
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('★ 非擁有者不可修改他人的認領', async () => {
    await assertFails(
      updateDoc(doc(dbFor(BOB), 'pledges/pledge-alice'), {
        quantity: 20,
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('★ 非擁有者不可刪除他人的認領', async () => {
    await assertFails(deleteDoc(doc(dbFor(BOB), 'pledges/pledge-alice')));
  });

  it('擁有者可以刪除自己的認領', async () => {
    await assertSucceeds(deleteDoc(doc(dbFor(ALICE), 'pledges/pledge-alice')));
  });

  it('不可把他人的認領「轉手」給自己', async () => {
    await assertFails(updateDoc(doc(dbFor(BOB), 'pledges/pledge-alice'), { userId: BOB }));
  });

  it('擁有者也不可把自己的認領轉給別人', async () => {
    await assertFails(updateDoc(doc(dbFor(ALICE), 'pledges/pledge-alice'), { userId: BOB }));
  });

  it('未登入不可建立認領', async () => {
    await assertFails(setDoc(doc(anonDb(), 'pledges/pledge-anon'), newPledge(ALICE)));
  });
});

// 完整認領流程：供給端（supply_items）與認領端（pledges）必須同時成立，
// 對應 supply_screen.dart `_showPledgeSheet` 的 Future.wait([...])。
describe('完整認領流程（supply_screen.dart 的實際呼叫）', () => {
  it('新認領：建立 pledge + 累加他人物資的 pledgedQty', async () => {
    const db = dbFor(BOB);
    await assertSucceeds(setDoc(doc(db, 'pledges/pledge-bob'), {
      userId: BOB,
      userName: 'Bob',
      itemId: 'water',
      itemName: '礦泉水',
      unit: '瓶',
      quantity: 7,
      status: 'pledged',
      pledgedAt: serverTimestamp(),
    }));
    await assertSucceeds(
      updateDoc(doc(db, 'supply_items/water'), { pledgedQty: increment(7) }),
    );
  });

  it('修改認領：更新 pledge 數量 + 以差額調整 pledgedQty（差額可為負）', async () => {
    const db = dbFor(ALICE);
    await assertSucceeds(updateDoc(doc(db, 'pledges/pledge-alice'), {
      quantity: 4,
      updatedAt: serverTimestamp(),
    }));
    // 先把總量墊到 10，再以 -6 的差額調整
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await updateDoc(doc(ctx.firestore(), 'supply_items/water'), { pledgedQty: 10 });
    });
    await assertSucceeds(
      updateDoc(doc(db, 'supply_items/water'), { pledgedQty: increment(-6) }),
    );
  });
});
