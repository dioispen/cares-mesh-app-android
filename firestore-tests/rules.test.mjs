// Firestore 安全規則測試（跑在 Firebase emulator 上，不會碰到任何線上專案）
//
// 執行方式（在 firestore-tests/ 內）：
//   npm install
//   npm test
//
// 測試重點：
//   issue #34
//   - supply_items：共用型錄，沒有擁有者，只能改非負計數欄位
//   - supply_requests / supply_pledges：只有紀錄擁有者能讀、改、刪
//   最關鍵的一條是「使用者能認領別人建立的物資」——那是加擁有者檢查最容易弄壞的地方。
//
//   issue #33
//   - health_reports：含 Detail Tier 全部欄位，只有 Reporter 本人與救援者可讀
//   - rescuers：救援者身分的唯一依據，客戶端一律不可寫（不可自我提權）
//   - users：含電話、緊急聯絡人、病史，只能讀自己的
//   最關鍵的一條是「在 users 自填 role 不會變成救援者」——角色機制最容易寫錯的地方。

import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, it } from 'node:test';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  increment,
  query,
  serverTimestamp,
  setDoc,
  updateDoc,
  where,
  writeBatch,
} from 'firebase/firestore';

const ALICE = 'uid-alice';
const BOB = 'uid-bob';
const CAROL = 'uid-carol';
const RESCUER = 'uid-rescuer';

let testEnv;

const seedItem = {
  name: '礦泉水',
  unit: '瓶',
  category: '食品飲水',
  inventoryQty: 500,
  totalRequestedQty: 0,
  totalPledgedQty: 0,
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
    // 救援者身分只能由後台（Firebase console / Admin SDK）寫入
    await setDoc(doc(db, `rescuers/${RESCUER}`), { grantedAt: new Date() });
    await setDoc(doc(db, 'health_reports/report-alice'), {
      id: 'report-alice',
      reporterId: ALICE,
      name: 'Alice',
      area: '台北市中正區',
      status: '重傷',
      description: '左腿骨折，無法行走',
      lat: 25.0339,
      lng: 121.5645,
      reportTime: new Date().toISOString(),
    });
    await setDoc(doc(db, `users/${ALICE}`), {
      id: ALICE,
      name: 'Alice',
      phone: '0912345678',
      emergencyContactPhone: '0987654321',
      medicalInfo: '盤尼西林過敏',
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

  // ★ issue #34：共用型錄不可做擁有者比對，否則無法登記他人建立的物資。
  it('★ 使用者可以在共用物資上累加需求與捐贈計數', async () => {
    await assertSucceeds(
      updateDoc(doc(dbFor(BOB), 'supply_items/water'), {
        totalRequestedQty: increment(5),
        totalPledgedQty: increment(3),
      }),
    );
  });

  it('未登入不可更新計數', async () => {
    await assertFails(
      updateDoc(doc(anonDb(), 'supply_items/water'), {
        totalPledgedQty: increment(5),
      }),
    );
  });

  it('不可竄改 name', async () => {
    await assertFails(updateDoc(doc(dbFor(BOB), 'supply_items/water'), { name: '假資料' }));
  });

  it('不可在更新計數時夾帶型錄欄位', async () => {
    await assertFails(
      updateDoc(doc(dbFor(BOB), 'supply_items/water'), {
        totalPledgedQty: increment(1),
        category: '衣物',
      }),
    );
  });

  it('計數不可設為負數或非整數', async () => {
    await assertFails(
      updateDoc(doc(dbFor(BOB), 'supply_items/water'), { totalPledgedQty: -1 }),
    );
    await assertFails(
      updateDoc(doc(dbFor(BOB), 'supply_items/water'), { totalRequestedQty: 'many' }),
    );
  });

  it('任何人都不可刪除', async () => {
    await assertFails(deleteDoc(doc(dbFor(BOB), 'supply_items/water')));
    await assertFails(deleteDoc(doc(dbFor(ALICE), 'supply_items/water')));
  });

  it('目前 Dart 模型的種子欄位可以建立', async () => {
    await assertSucceeds(setDoc(doc(dbFor(ALICE), 'supply_items/blanket'), {
      ...seedItem,
      name: '毛毯',
      unit: '條',
      category: '生活用品',
      inventoryQty: 150,
    }));
  });

  it('建立時夾帶多餘欄位會被擋下', async () => {
    await assertFails(setDoc(doc(dbFor(ALICE), 'supply_items/evil'), {
      ...seedItem,
      injected: 'x',
    }));
  });

  it('建立時不得預填需求或捐贈總量', async () => {
    await assertFails(setDoc(doc(dbFor(ALICE), 'supply_items/evil'), {
      ...seedItem,
      totalRequestedQty: 9999,
    }));
    await assertFails(setDoc(doc(dbFor(ALICE), 'supply_items/evil'), {
      ...seedItem,
      totalPledgedQty: 9999,
    }));
  });

  it('建立時欄位型別錯誤會被擋下', async () => {
    await assertFails(setDoc(doc(dbFor(ALICE), 'supply_items/evil'), {
      ...seedItem,
      inventoryQty: '500',
    }));
  });

  it('建立時缺欄位會被擋下', async () => {
    await assertFails(setDoc(doc(dbFor(ALICE), 'supply_items/evil'), { name: '只有名字' }));
  });
});

describe('supply_requests', () => {
  const newRequest = (uid) => ({
    userId: uid,
    userName: 'Someone',
    itemId: 'water',
    itemName: '礦泉水',
    unit: '瓶',
    quantity: 3,
    status: 'pending',
    createdAt: serverTimestamp(),
  });

  it('可以建立自己的物資申請', async () => {
    await assertSucceeds(
      setDoc(doc(dbFor(BOB), 'supply_requests/request-bob'), newRequest(BOB)),
    );
  });

  it('不可冒用他人 userId 建立申請', async () => {
    await assertFails(
      setDoc(doc(dbFor(BOB), 'supply_requests/request-fake'), newRequest(ALICE)),
    );
  });

  it('數量必須為正整數，且狀態必須從 pending 開始', async () => {
    await assertFails(setDoc(doc(dbFor(BOB), 'supply_requests/request-zero'), {
      ...newRequest(BOB),
      quantity: 0,
    }));
    await assertFails(setDoc(doc(dbFor(BOB), 'supply_requests/request-status'), {
      ...newRequest(BOB),
      status: 'fulfilled',
    }));
  });

  it('建立時不可夾帶未定義欄位', async () => {
    await assertFails(setDoc(doc(dbFor(BOB), 'supply_requests/request-extra'), {
      ...newRequest(BOB),
      role: 'admin',
    }));
  });

  it('只有擁有者可以讀取、更新或刪除申請', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'supply_requests/request-alice'), newRequest(ALICE));
    });

    await assertSucceeds(getDoc(doc(dbFor(ALICE), 'supply_requests/request-alice')));
    await assertFails(getDoc(doc(dbFor(BOB), 'supply_requests/request-alice')));
    await assertSucceeds(updateDoc(doc(dbFor(ALICE), 'supply_requests/request-alice'), {
      quantity: 4,
      status: 'cancelled',
    }));
    await assertFails(updateDoc(doc(dbFor(BOB), 'supply_requests/request-alice'), {
      quantity: 4,
    }));
    await assertFails(updateDoc(doc(dbFor(ALICE), 'supply_requests/request-alice'), {
      userId: BOB,
    }));
    await assertSucceeds(deleteDoc(doc(dbFor(ALICE), 'supply_requests/request-alice')));
    await assertFails(deleteDoc(doc(dbFor(BOB), 'supply_requests/request-alice')));
  });
});

describe('supply_pledges', () => {
  const newSupplyPledge = (uid) => ({
    userId: uid,
    userName: 'Someone',
    itemId: 'water',
    itemName: '礦泉水',
    unit: '瓶',
    qty: 3,
    status: 'pledged',
    pledgedAt: serverTimestamp(),
  });

  it('可以建立自己的物資認領', async () => {
    await assertSucceeds(
      setDoc(doc(dbFor(BOB), 'supply_pledges/pledge-bob'), newSupplyPledge(BOB)),
    );
  });

  it('不可冒用他人 userId 建立認領', async () => {
    await assertFails(
      setDoc(doc(dbFor(BOB), 'supply_pledges/pledge-fake'), newSupplyPledge(ALICE)),
    );
  });

  it('數量必須為正整數，且狀態必須從 pledged 開始', async () => {
    await assertFails(setDoc(doc(dbFor(BOB), 'supply_pledges/pledge-zero'), {
      ...newSupplyPledge(BOB),
      qty: 0,
    }));
    await assertFails(setDoc(doc(dbFor(BOB), 'supply_pledges/pledge-status'), {
      ...newSupplyPledge(BOB),
      status: 'delivered',
    }));
  });

  it('建立時不可夾帶未定義欄位', async () => {
    await assertFails(setDoc(doc(dbFor(BOB), 'supply_pledges/pledge-extra'), {
      ...newSupplyPledge(BOB),
      role: 'admin',
    }));
  });

  it('只有擁有者可以讀取、更新或刪除認領', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'supply_pledges/pledge-alice'), newSupplyPledge(ALICE));
    });

    await assertSucceeds(getDoc(doc(dbFor(ALICE), 'supply_pledges/pledge-alice')));
    await assertFails(getDoc(doc(dbFor(BOB), 'supply_pledges/pledge-alice')));
    await assertSucceeds(updateDoc(doc(dbFor(ALICE), 'supply_pledges/pledge-alice'), {
      qty: 4,
      status: 'delivered',
    }));
    await assertFails(updateDoc(doc(dbFor(BOB), 'supply_pledges/pledge-alice'), {
      qty: 4,
    }));
    await assertFails(updateDoc(doc(dbFor(ALICE), 'supply_pledges/pledge-alice'), {
      userId: BOB,
    }));
    await assertSucceeds(deleteDoc(doc(dbFor(ALICE), 'supply_pledges/pledge-alice')));
    await assertFails(deleteDoc(doc(dbFor(BOB), 'supply_pledges/pledge-alice')));
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

// 對應 supply_screen.dart 的 batch commit，保證紀錄與共用計數可原子寫入。
describe('物資申請與認領批次流程（supply_screen.dart）', () => {
  it('申請：建立 supply_requests + 累加 totalRequestedQty', async () => {
    const db = dbFor(BOB);
    const batch = writeBatch(db);
    batch.set(doc(db, 'supply_requests/request-bob'), {
      userId: BOB,
      userName: 'Bob',
      itemId: 'water',
      itemName: '礦泉水',
      unit: '瓶',
      quantity: 7,
      status: 'pending',
      createdAt: serverTimestamp(),
    });
    batch.update(doc(db, 'supply_items/water'), {
      totalRequestedQty: increment(7),
    });
    await assertSucceeds(batch.commit());
  });

  it('認領：建立 supply_pledges + 累加他人建立物資的 totalPledgedQty', async () => {
    const db = dbFor(BOB);
    const batch = writeBatch(db);
    batch.set(doc(db, 'supply_pledges/pledge-bob'), {
      userId: BOB,
      userName: 'Bob',
      itemId: 'water',
      itemName: '礦泉水',
      unit: '瓶',
      qty: 7,
      status: 'pledged',
      pledgedAt: serverTimestamp(),
    });
    batch.update(doc(db, 'supply_items/water'), {
      totalPledgedQty: increment(7),
    });
    await assertSucceeds(batch.commit());
  });
});

// ADR-0005：Health Report 在後端分成兩份文件。
//   health_reports/{uid}            Detail Tier：任何登入帳號都能讀
//   health_report_sensitive/{uid}   Sensitive Tier：本人，或正接著這筆任務的 Verified Rescuer
describe('health_reports／health_report_sensitive 分層揭露（ADR-0005）', () => {
  const detailTier = (uid, extra = {}) => ({
    id: `report-${uid}`,
    reporterId: uid,
    name: 'Someone',
    area: '台北市中正區',
    status: '重傷',
    description: '骨折',
    lat: 25.0,
    lng: 121.5,
    reportTime: '2026-10-12T10:00:00.000Z',
    ...extra,
  });
  const sensitiveTier = (uid) => ({
    reporterId: uid,
    phone: '0912345678',
    bloodType: 'O',
    medicalInfo: '盤尼西林過敏',
    emergencyContactName: '王大明',
    emergencyContactPhone: '0987654321',
    emergencyContactRelation: '父親',
  });
  const seed = async (uid, extra = {}) => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), `health_reports/${uid}`), detailTier(uid, extra));
      await setDoc(doc(ctx.firestore(), `health_report_sensitive/${uid}`), sensitiveTier(uid));
    });
  };
  const sensitiveOf = (reader, uid) =>
    getDoc(doc(dbFor(reader), `health_report_sensitive/${uid}`));

  describe('Detail Tier', () => {
    it('★ 任何登入帳號都能讀他人的回報', async () => {
      await seed(ALICE);
      await assertSucceeds(getDoc(doc(dbFor(BOB), `health_reports/${ALICE}`)));
    });

    it('★ 任何登入帳號都能列出待救援回報（health_screen 的互助任務查詢）', async () => {
      await seed(ALICE);
      await assertSucceeds(getDocs(query(
        collection(dbFor(BOB), 'health_reports'),
        where('status', 'in', ['輕傷', '重傷']),
      )));
    });

    it('未登入不可讀', async () => {
      await seed(ALICE);
      await assertFails(getDoc(doc(anonDb(), `health_reports/${ALICE}`)));
    });

    it('可以建立自己的回報（文件 ID 是自己的 uid）', async () => {
      await assertSucceeds(setDoc(doc(dbFor(BOB), `health_reports/${BOB}`), detailTier(BOB)));
    });

    it('不可冒用他人 reporterId 建立回報', async () => {
      await assertFails(setDoc(doc(dbFor(BOB), 'health_reports/report-fake'), detailTier(ALICE)));
    });

    it('★ 建立時不能夾帶 Sensitive Tier 欄位（這份文件大家都讀得到）', async () => {
      await assertFails(setDoc(doc(dbFor(BOB), `health_reports/${BOB}`), {
        ...detailTier(BOB),
        phone: '0900000000',
      }));
    });

    it('★ 更新時也不能補上 Sensitive Tier 欄位', async () => {
      await seed(ALICE);
      await assertFails(
        updateDoc(doc(dbFor(ALICE), `health_reports/${ALICE}`), { bloodType: 'O' }),
      );
    });

    it('Reporter 可更新自己回報的狀態', async () => {
      await seed(ALICE);
      await assertSucceeds(
        updateDoc(doc(dbFor(ALICE), `health_reports/${ALICE}`), { status: '輕傷' }),
      );
    });

    it('Reporter 不可把自己的回報轉手給他人（會連帶交出 Sensitive Tier 的讀取權）', async () => {
      await seed(ALICE);
      await assertFails(
        updateDoc(doc(dbFor(ALICE), `health_reports/${ALICE}`), { reporterId: BOB }),
      );
    });

    it('Verified Rescuer 不因身分而能竄改或刪除他人的回報', async () => {
      await seed(ALICE);
      await assertFails(
        updateDoc(doc(dbFor(RESCUER), `health_reports/${ALICE}`), { status: '安全' }),
      );
      await assertFails(deleteDoc(doc(dbFor(RESCUER), `health_reports/${ALICE}`)));
    });
  });

  // 健康回報的狀況調查（ADR-0007）：survey／surveySensitive 是巢狀 map，最外層的 hasOnly()
  // 擋不到裡面的鍵，所以兩份文件各自鎖住能有哪些鍵。
  describe('狀況調查 survey 的分層（ADR-0007）', () => {
    const detailSurvey = {
      mobility: '需要協助才能移動',
      location: '家中',
      companions: 2,
      housing: '輕微損壞，仍可居住',
      needs: ['飲用水', '藥品'],
    };
    const sensitiveSurvey = { vulnerable: ['長者'], notes: '降血壓藥快用完了' };

    it('Detail Tier 可以帶公開的調查項目', async () => {
      await assertSucceeds(setDoc(
        doc(dbFor(BOB), `health_reports/${BOB}`),
        detailTier(BOB, { survey: detailSurvey }),
      ));
    });

    it('沒有填調查（survey 為 null）也可以回報', async () => {
      await assertSucceeds(setDoc(
        doc(dbFor(BOB), `health_reports/${BOB}`),
        detailTier(BOB, { survey: null }),
      ));
    });

    it('★ Detail Tier 的 survey 不能夾帶「需要特別照顧的人」', async () => {
      await assertFails(setDoc(
        doc(dbFor(BOB), `health_reports/${BOB}`),
        detailTier(BOB, { survey: { ...detailSurvey, vulnerable: ['身心障礙者'] } }),
      ));
    });

    it('★ Detail Tier 的 survey 不能夾帶補充說明（自由文字）', async () => {
      await seed(ALICE);
      await assertFails(updateDoc(
        doc(dbFor(ALICE), `health_reports/${ALICE}`),
        { survey: { ...detailSurvey, notes: '有心臟病' } },
      ));
    });

    it('Detail Tier 的 survey 必須是 map', async () => {
      await assertFails(setDoc(
        doc(dbFor(BOB), `health_reports/${BOB}`),
        detailTier(BOB, { survey: '有心臟病' }),
      ));
    });

    it('Sensitive Tier 可以帶敏感的調查項目', async () => {
      await assertSucceeds(setDoc(
        doc(dbFor(BOB), `health_report_sensitive/${BOB}`),
        { ...sensitiveTier(BOB), surveySensitive: sensitiveSurvey },
      ));
    });

    it('Sensitive Tier 的 surveySensitive 不能帶其他鍵', async () => {
      await assertFails(setDoc(
        doc(dbFor(BOB), `health_report_sensitive/${BOB}`),
        { ...sensitiveTier(BOB), surveySensitive: { ...sensitiveSurvey, password: 'x' } },
      ));
    });
  });

  describe('Sensitive Tier', () => {
    it('Reporter 可讀寫自己的 Sensitive Tier', async () => {
      await seed(ALICE);
      await assertSucceeds(sensitiveOf(ALICE, ALICE));
      await assertSucceeds(setDoc(
        doc(dbFor(ALICE), `health_report_sensitive/${ALICE}`),
        { ...sensitiveTier(ALICE), phone: '0911111111' },
      ));
    });

    it('還沒回報過的人也能讀自己的 Sensitive Tier（文件不存在）', async () => {
      await assertSucceeds(sensitiveOf(BOB, BOB));
    });

    it('★ 一般登入帳號讀不到他人的 Sensitive Tier', async () => {
      await seed(ALICE);
      await assertFails(sensitiveOf(BOB, ALICE));
    });

    it('未登入讀不到', async () => {
      await seed(ALICE);
      await assertFails(getDoc(doc(anonDb(), `health_report_sensitive/${ALICE}`)));
    });

    it('★ Verified Rescuer 還沒接下這筆任務時讀不到', async () => {
      await seed(ALICE);
      await assertFails(sensitiveOf(RESCUER, ALICE));
    });

    it('★ 沒認證的協助者接下任務了也讀不到', async () => {
      await seed(ALICE, { taskStatus: 'accepted', helperId: BOB });
      await assertFails(sensitiveOf(BOB, ALICE));
    });

    it('★ Verified Rescuer 接下這筆任務後讀得到', async () => {
      await seed(ALICE, { taskStatus: 'accepted', helperId: RESCUER });
      await assertSucceeds(sensitiveOf(RESCUER, ALICE));
    });

    it('★ 只解鎖自己接的那幾筆：接了 Alice 的任務讀不到 Carol 的', async () => {
      await seed(ALICE, { taskStatus: 'accepted', helperId: RESCUER });
      await seed(CAROL);
      await assertFails(sensitiveOf(RESCUER, CAROL));
    });

    it('★ 任務被別人接走時，Verified Rescuer 讀不到', async () => {
      await seed(ALICE, { taskStatus: 'accepted', helperId: BOB });
      await assertFails(sensitiveOf(RESCUER, ALICE));
    });

    it('★ 完成任務之後就讀不到', async () => {
      await seed(ALICE, { taskStatus: 'done', helperId: RESCUER });
      await assertFails(sensitiveOf(RESCUER, ALICE));
    });

    it('★ 實際流程：認領 → 讀得到 → 放棄 → 讀不到', async () => {
      await seed(ALICE);
      const ref = doc(dbFor(RESCUER), `health_reports/${ALICE}`);
      await assertSucceeds(updateDoc(ref, { taskStatus: 'accepted', helperId: RESCUER }));
      await assertSucceeds(sensitiveOf(RESCUER, ALICE));
      await assertSucceeds(updateDoc(ref, { taskStatus: 'waiting', helperId: null }));
      await assertFails(sensitiveOf(RESCUER, ALICE));
    });

    it('沒有對應的 Detail Tier 文件時，Verified Rescuer 讀不到', async () => {
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `health_report_sensitive/${CAROL}`), sensitiveTier(CAROL));
      });
      await assertFails(sensitiveOf(RESCUER, CAROL));
    });

    it('不能替別人寫 Sensitive Tier', async () => {
      await assertFails(setDoc(
        doc(dbFor(BOB), `health_report_sensitive/${ALICE}`),
        sensitiveTier(ALICE),
      ));
      await assertFails(setDoc(
        doc(dbFor(BOB), `health_report_sensitive/${ALICE}`),
        sensitiveTier(BOB),
      ));
    });

    it('接著任務的 Verified Rescuer 也不能改或刪 Sensitive Tier', async () => {
      await seed(ALICE, { taskStatus: 'accepted', helperId: RESCUER });
      const ref = doc(dbFor(RESCUER), `health_report_sensitive/${ALICE}`);
      await assertFails(updateDoc(ref, { phone: '0900000000' }));
      await assertFails(deleteDoc(ref));
    });

    it('不能夾帶未定義的欄位', async () => {
      await assertFails(setDoc(doc(dbFor(BOB), `health_report_sensitive/${BOB}`), {
        ...sensitiveTier(BOB),
        idNumber: 'A123456789',
      }));
    });
  });
});

describe('rescuers（issue #33：救援者身分不可自我提權）', () => {
  it('★ 使用者不可把自己登記為救援者', async () => {
    await assertFails(setDoc(doc(dbFor(BOB), `rescuers/${BOB}`), { grantedAt: new Date() }));
  });

  it('★ 救援者也不可替他人授權', async () => {
    await assertFails(
      setDoc(doc(dbFor(RESCUER), `rescuers/${BOB}`), { grantedAt: new Date() }),
    );
  });

  it('救援者不可改動或撤銷自己的身分文件', async () => {
    await assertFails(updateDoc(doc(dbFor(RESCUER), `rescuers/${RESCUER}`), { extra: 1 }));
    await assertFails(deleteDoc(doc(dbFor(RESCUER), `rescuers/${RESCUER}`)));
  });

  it('★ 在 users 文件自填 role 不會取得 Sensitive Tier 讀取權', async () => {
    // 就算 Bob 接下了 Alice 的任務，自填的 role 也不算 Verified Rescuer。
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), `health_reports/${ALICE}`), {
        reporterId: ALICE,
        status: '重傷',
        taskStatus: 'accepted',
        helperId: BOB,
      });
      await setDoc(doc(ctx.firestore(), `health_report_sensitive/${ALICE}`), {
        reporterId: ALICE,
        phone: '0912345678',
      });
    });
    const db = dbFor(BOB);
    await assertSucceeds(setDoc(doc(db, `users/${BOB}`), { id: BOB, role: 'rescuer' }));
    await assertFails(getDoc(doc(db, `health_report_sensitive/${ALICE}`)));
  });

  it('使用者可讀自己的救援者身分文件（供 App 判斷顯示）', async () => {
    await assertSucceeds(getDoc(doc(dbFor(RESCUER), `rescuers/${RESCUER}`)));
    await assertSucceeds(getDoc(doc(dbFor(BOB), `rescuers/${BOB}`)));
  });

  it('不可讀取他人的救援者身分文件', async () => {
    await assertFails(getDoc(doc(dbFor(BOB), `rescuers/${RESCUER}`)));
  });
});

describe('users（issue #33：個人檔案含 PII，只能讀自己的）', () => {
  it('★ 不可讀取他人的個人檔案', async () => {
    await assertFails(getDoc(doc(dbFor(BOB), `users/${ALICE}`)));
  });

  it('可讀自己的個人檔案（login / setup 流程）', async () => {
    await assertSucceeds(getDoc(doc(dbFor(ALICE), `users/${ALICE}`)));
  });

  it('可寫入自己的個人檔案（verify_email 流程）', async () => {
    await assertSucceeds(setDoc(doc(dbFor(BOB), `users/${BOB}`), { id: BOB, name: 'Bob' }));
  });

  it('不可寫入他人的個人檔案', async () => {
    await assertFails(setDoc(doc(dbFor(BOB), `users/${ALICE}`), { id: ALICE, name: '竄改' }));
  });

  it('未登入不可讀', async () => {
    await assertFails(getDoc(doc(anonDb(), `users/${ALICE}`)));
  });
});

// health_reports 的任務狀態欄位（taskStatus / helperId）。
//
// 這裡的關鍵是：協助者**不是**回報者，卻必須能改動別人的文件才能認領任務——
// 跟 supply_items 認領流程同一類問題。而 health_reports 文件裡有姓名、傷勢、
// 精確座標，所以放寬的範圍必須嚴格限制在那兩個欄位上。
describe('health_reports 互助任務狀態', () => {
  const seedReport = {
    id: 'report-uuid',
    reporterId: ALICE,
    name: 'Alice',
    area: '台北市中正區',
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

// 一人一筆：health_reports 的文件 ID 就是回報者的 uid（health_screen.dart 的 _select）。
describe('health_reports 一人一筆', () => {
  const ownReport = (uid) => ({
    id: 'report-uuid',
    reporterId: uid,
    name: 'Alice',
    area: '台北市中正區',
    status: '輕傷',
    description: '割傷',
    lat: null,
    lng: null,
    reportTime: '2026-10-04T10:00:00.000Z',
  });

  it('可以在自己的 uid 底下建立回報', async () => {
    await assertSucceeds(setDoc(doc(dbFor(ALICE), `health_reports/${ALICE}`), ownReport(ALICE)));
  });

  it('★ 不能先搶走別人的文件 ID（即使 reporterId 填自己）', async () => {
    await assertFails(setDoc(doc(dbFor(BOB), `health_reports/${ALICE}`), ownReport(BOB)));
  });

  it('不能用隨機 ID 建立回報（舊版 add() 的寫法）', async () => {
    await assertFails(setDoc(doc(dbFor(ALICE), 'health_reports/random-id'), ownReport(ALICE)));
  });

  it('還沒回報過的人可以監聽自己 uid 的文件（文件不存在）', async () => {
    await assertSucceeds(getDoc(doc(dbFor(ALICE), `health_reports/${ALICE}`)));
  });

  it('本人可以覆寫自己的回報', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), `health_reports/${ALICE}`), ownReport(ALICE));
    });
    await assertSucceeds(setDoc(doc(dbFor(ALICE), `health_reports/${ALICE}`), {
      ...ownReport(ALICE),
      status: '安全',
      description: null,
    }));
  });
});

// SOS 是 Health Report 上的標記（ADR-0004、#83）：寫在 Reporter 自己的 health_reports/{uid}，
// 沿用 Detail Tier 的讀取規則與一人一份；sos_requests 停用。
describe('SOS（#83：health_reports 的 sos 欄位，停用 sos_requests）', () => {
  const sosReport = (uid, extra = {}) => ({
    id: 'report-uuid',
    reporterId: uid,
    name: 'Alice',
    area: '台北市中正區',
    status: '未宣告',
    lat: 25.033,
    lng: 121.5654,
    reportTime: '2026-10-22T10:00:00.000Z',
    sos: true,
    ...extra,
  });
  const seed = async (extra = {}) => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), `health_reports/${ALICE}`), sosReport(ALICE, extra));
    });
  };
  const seedLegacySos = async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'sos_requests/legacy-alice'), {
        userId: ALICE,
        userName: 'Alice',
        phone: '0912345678',
        latitude: 25.033,
        longitude: 121.5654,
        bloodType: 'O',
        medicalInfo: '盤尼西林過敏',
        status: 'active',
      });
    });
  };

  it('★ 本人可以建立帶 sos 的回報（Status 未宣告）', async () => {
    await assertSucceeds(setDoc(doc(dbFor(ALICE), `health_reports/${ALICE}`), sosReport(ALICE)));
  });

  it('sos 必須是布林值', async () => {
    await assertFails(setDoc(
      doc(dbFor(ALICE), `health_reports/${ALICE}`),
      sosReport(ALICE, { sos: 'yes' }),
    ));
  });

  it('★ 帶 sos 的回報沿用 Detail Tier 的讀取規則：登入帳號讀得到，未登入讀不到', async () => {
    await seed();
    await assertSucceeds(getDoc(doc(dbFor(BOB), `health_reports/${ALICE}`)));
    await assertFails(getDoc(doc(anonDb(), `health_reports/${ALICE}`)));
  });

  it('★ 互助任務查詢涵蓋「未宣告」', async () => {
    await seed();
    await assertSucceeds(getDocs(query(
      collection(dbFor(BOB), 'health_reports'),
      where('status', 'in', ['輕傷', '重傷', '未宣告']),
    )));
  });

  it('★ Status 不變時本人只改 sos、位置與時間，已接手的任務維持已接手', async () => {
    await seed({ status: '重傷', sos: false, taskStatus: 'accepted', helperId: BOB });
    // sos_screen.dart 以 merge 寫入，等同只改這幾個欄位
    await assertSucceeds(updateDoc(doc(dbFor(ALICE), `health_reports/${ALICE}`), {
      reporterId: ALICE,
      status: '重傷',
      sos: true,
      lat: 25.04,
      lng: 121.57,
      reportTime: '2026-10-22T10:05:00.000Z',
    }));
    const snap = await getDoc(doc(dbFor(BOB), `health_reports/${ALICE}`));
    if (snap.data().taskStatus !== 'accepted' || snap.data().helperId !== BOB) {
      throw new Error(`任務被打回：${JSON.stringify(snap.data())}`);
    }
  });

  it('★ 協助者不能改動 sos', async () => {
    await seed({ status: '重傷', taskStatus: 'accepted', helperId: BOB });
    const ref = doc(dbFor(BOB), `health_reports/${ALICE}`);
    await assertFails(updateDoc(ref, { sos: false }));
    await assertFails(updateDoc(ref, { taskStatus: 'done', helperId: BOB, sos: false }));
  });

  it('★ 一般登入帳號讀不到他人在 sos_requests 的舊資料（#64）', async () => {
    await seedLegacySos();
    await assertFails(getDoc(doc(dbFor(BOB), 'sos_requests/legacy-alice')));
    await assertFails(getDocs(collection(dbFor(BOB), 'sos_requests')));
  });

  it('本人仍讀得到自己在 sos_requests 的舊資料', async () => {
    await seedLegacySos();
    await assertSucceeds(getDoc(doc(dbFor(ALICE), 'sos_requests/legacy-alice')));
  });

  it('★ Verified Rescuer 也讀不到 sos_requests 的舊資料：沒有任務可以對應（ADR-0005）', async () => {
    await seedLegacySos();
    await assertFails(getDoc(doc(dbFor(RESCUER), 'sos_requests/legacy-alice')));
  });

  it('★ 不能再新建 sos_requests（連自己的也不行）', async () => {
    await assertFails(setDoc(doc(dbFor(ALICE), 'sos_requests/new'), {
      userId: ALICE,
      status: 'active',
    }));
  });
});
