interface StoreProductIntroduction {
  productId: string;
  introduction: string;
}

// Purchase rights and renewal terms stay visible outside the collapsible story;
// keeping them out of this copy avoids hiding or duplicating purchase terms.
const STORE_PRODUCT_INTRODUCTIONS: StoreProductIntroduction[] = [
  {
    productId: 'onebeat.character.cloud',
    introduction: '一朵会走路的云：蓝色独眼，背后一对小翅膀。步子轻得像在飘，落拍却稳稳当当，不抢也不拖。性子温吞好脾气，心里却藏着点小倔强：认定的拍子，谁催也不乱。'
  },
  {
    productId: 'onebeat.character.teapot',
    introduction: '壶里装着热茶，也装着稳当当的鼓点。圆润可靠的大厅常客，步调温厚、不紧不慢。她爱操心、念旧，总怕队友跟不上，宁可自己放慢半步等一等。'
  },
  {
    productId: 'onebeat.character.wave',
    introduction: '她攥着拳头大步向前，起落像一道浪线——有起伏，每一拍却都落在线上。她外向直率、闲不住，心情全写在脸上，场子越热闹越来劲。'
  },
  {
    productId: 'onebeat.character.mismatch',
    introduction: '酷脸推进，条纹上身，节拍当头。表面满不在乎，其实很在意别人的目光——嘴上不说，脚下从不敷衍。准备好成为最抢镜的那一位。'
  },
  {
    productId: 'onebeat.character.scooter',
    introduction: '黑头盔压低，护目镜遮眼，青柠夹克被风鼓起。十六帧动作两拍一轮，每一蹬都踩在点上。冷着脸，从不掉拍。话少、独来独往，不爱被人盯着看。'
  },
  {
    productId: 'onebeat.character.lilroll',
    introduction: '紫调、轻灵、带点少年气——「贴地飞行」说的是姿态，不是乱拍。他好奇心旺、一刻不停，偶尔冒失，却天生乐观，摔一跤也笑着爬起来。'
  },
  {
    productId: 'onebeat.character.lamp',
    introduction: '灯罩压到眉下，只留两只半睁的眼。蓝条纹睡衣，紫拖鞋，插头尾巴拖在身后。他走得很慢，像还没醒，脚步却一步不落。他内向慢热，怕吵也怕黑，所以总把那盏灯留给身后的人。'
  },
  {
    productId: 'onebeat.scene.neon_street',
    introduction: '把行进场景换成「霓虹街口」：远天霓虹、近处楼群与湿润路面层层视差，角色在雨夜城市里踩点前进。'
  },
  {
    productId: 'onebeat.pass.monthly',
    introduction: '给认真踩点的人一条「全开」捷径，把节拍编进你的练习里。'
  }
];

/** Returns story copy for a known paid product; an unknown product has no introduction. */
export function storeProductIntroduction(productId: string): string {
  const product = STORE_PRODUCT_INTRODUCTIONS.find((item: StoreProductIntroduction) => item.productId === productId);
  return product?.introduction ?? '';
}
