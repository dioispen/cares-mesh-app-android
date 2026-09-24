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
const CAROL = 'uid-carol';

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

// health_reports 的任務狀態欄位（taskStatus / helperId）。
//
// 這裡的關鍵是：協助者**不是**回報者，卻必須能改動別人的文件才能認領任務——
// 跟 supply_items 認領流程同一類問題。而 health_reports 文件裡有姓名、電話、
// 血型、精確座標，所以放寬的範圍必須嚴格限制在那兩個欄位上。
describe('health_reports 互助任務狀態', () => {
  const seedReport = {
    id: 'report-uuid',
    reporterId: ALICE,
    name: 'Alice',
    phone: '0912345678',
    bloodType: 'O',
    status: '重傷',
    description: '頭部受傷',
    lat: 25.033,
    lng: 121.5654,
    reportTime: '2026-09-24T10:00:00.000Z',
  };

  const seed = async (extra = {}) => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'health_reports/report-alice'), {
        ...seedReport,
        ...extra,
      });
    });
  };

  it('未登入不能改任務狀態', async () => {
    await seed();
    await assertFails(updateDoc(doc(anonDb(), 'health_reports/report-alice'), {
      taskStatus: 'accepted',
      helperId: BOB,
    }));
  });

  it('協助者可以認領別人的回報（含還沒有 taskStatus 欄位的舊文件）', async () => {
    await seed();
    await assertSucceeds(updateDoc(doc(dbFor(BOB), 'health_reports/report-alice'), {
      taskStatus: 'accepted',
      helperId: BOB,
    }));
  });

  it('不能冒名把 helperId 填成第三人', async () => {
    await seed();
    await assertFails(updateDoc(doc(dbFor(BOB), 'health_reports/report-alice'), {
      taskStatus: 'accepted',
      helperId: CAROL,
    }));
  });

  it('認領時不得順手竄改傷勢或聯絡資訊', async () => {
    await seed();
    const db = dbFor(BOB);
    await assertFails(updateDoc(doc(db, 'health_reports/report-alice'), {
      taskStatus: 'accepted',
      helperId: BOB,
      status: '安全',
    }));
    await assertFails(updateDoc(doc(db, 'health_reports/report-alice'), {
      taskStatus: 'accepted',
      helperId: BOB,
      phone: '0900000000',
    }));
  });

  it('已被接走的任務不能被別人搶走', async () => {
    await seed({ taskStatus: 'accepted', helperId: BOB });
    await assertFails(updateDoc(doc(dbFor(CAROL), 'health_reports/report-alice'), {
      taskStatus: 'accepted',
      helperId: CAROL,
    }));
  });

  it('只有當初認領的人能標記完成', async () => {
    await seed({ taskStatus: 'accepted', helperId: BOB });
    await assertFails(updateDoc(doc(dbFor(CAROL), 'health_reports/report-alice'), {
      taskStatus: 'done',
      helperId: CAROL,
    }));
    await assertSucceeds(updateDoc(doc(dbFor(BOB), 'health_reports/report-alice'), {
      taskStatus: 'done',
      helperId: BOB,
    }));
  });

  it('認領者可以放棄任務，任務回到等待中', async () => {
    await seed({ taskStatus: 'accepted', helperId: BOB });
    await assertSucceeds(updateDoc(doc(dbFor(BOB), 'health_reports/report-alice'), {
      taskStatus: 'waiting',
      helperId: null,
    }));
  });

  it('放棄之後，另一位夥伴可以接手（helperId 明確為 null 的狀態）', async () => {
    await seed({ taskStatus: 'accepted', helperId: BOB });
    await assertSucceeds(updateDoc(doc(dbFor(BOB), 'health_reports/report-alice'), {
      taskStatus: 'waiting',
      helperId: null,
    }));
    await assertSucceeds(updateDoc(doc(dbFor(CAROL), 'health_reports/report-alice'), {
      taskStatus: 'accepted',
      helperId: CAROL,
    }));
  });

  it('已完成的任務不能被翻回等待中', async () => {
    await seed({ taskStatus: 'done', helperId: BOB });
    await assertFails(updateDoc(doc(dbFor(BOB), 'health_reports/report-alice'), {
      taskStatus: 'waiting',
      helperId: null,
    }));
  });

  it('回報者本人仍然可以完整更新與刪除自己的回報', async () => {
    await seed();
    const db = dbFor(ALICE);
    await assertSucceeds(updateDoc(doc(db, 'health_reports/report-alice'), {
      status: '輕傷',
      description: '已包紮',
    }));
    await assertSucceeds(deleteDoc(doc(db, 'health_reports/report-alice')));
  });

  it('協助者不能刪除別人的回報', async () => {
    await seed({ taskStatus: 'accepted', helperId: BOB });
    await assertFails(deleteDoc(doc(dbFor(BOB), 'health_reports/report-alice')));
  });
});
