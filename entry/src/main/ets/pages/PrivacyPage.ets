import { router } from '@kit.ArkUI';
import { CORAL, INK, PAPER } from '../components/ComicKit';

@Entry
@Component
struct PrivacyPage {
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;

  @Builder
  private sectionTitle(title: string) {
    Text(title)
      .fontSize(17)
      .fontWeight(900)
      .fontColor(INK)
      .width('100%')
      .margin({ top: 20, bottom: 6 })
  }

  // Mirrors <h3> in privacy.html; keep this page and both HTML copies in sync.
  @Builder
  private subTitle(title: string) {
    Text(title)
      .fontSize(15)
      .fontWeight(FontWeight.Bold)
      .fontColor(INK)
      .width('100%')
      .margin({ top: 10, bottom: 2 })
  }

  @Builder
  private bodyText(content: string) {
    Text(content)
      .fontSize(14)
      .lineHeight(24)
      .fontColor('#333333')
      .width('100%')
  }

  @Builder
  private bulletText(content: string) {
    Row({ space: 8 }) {
      Text('•').fontSize(14).fontColor(CORAL).fontWeight(FontWeight.Bold)
      Text(content)
        .fontSize(14)
        .lineHeight(24)
        .fontColor('#333333')
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ top: 4 })
  }

  build() {
    Column() {
      Row() {
        Text('‹').fontSize(32).width(32).onClick(() => router.back())
        Text('隐私声明').fontSize(28).fontWeight(900).fontStyle(FontStyle.Italic)
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 8 + this.topSafeInset })

      Text('更新日期：2026年11月3日')
        .fontSize(12)
        .fontColor('#6A6A6A')
        .width('100%')
        .padding({ left: 18, right: 18, top: 4 })

      Text('开发者：李喆    应用名称：同拍（OneBeat）')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK)
        .width('100%')
        .padding({ left: 18, right: 18, top: 8 })

      Divider().color('#E8E2D6').margin({ top: 12, left: 18, right: 18 })

      Scroll() {
        Column({ space: 4 }) {
          this.bodyText('同拍是一款多人同步节拍器：附近的几台手机组成队伍，按同一节拍、节奏型或鼓机编排一起练习，也可以单人练习、录制行进视频并分享。本声明说明在使用这些功能时，本应用会处理哪些信息、为什么处理、存放在哪里，以及您如何管理这些信息。请在使用前仔细阅读。')

          this.sectionTitle('一、我们如何处理您的信息')
          this.subTitle('1. 保存在您设备上的信息')
          this.bodyText('以下信息只保存在您的设备上，不会上传到开发者服务器：')
          this.bulletText('您设置的昵称和所选角色；')
          this.bulletText('节拍设置，包括速度、拍号、拍点强弱、音色、节奏型，以及您保存的鼓机编排；')
          this.bulletText('蓝牙耳机延迟校准结果，用于让耳机里的节拍与其他设备对齐；')
          this.bulletText('录制的行进视频、视频封面，以及分享打卡记录；')
          this.bulletText('奇遇小铺的本地权益缓存（包括从华为核验后的已购商品与月卡状态摘要，不含购买凭据）、鼓机试用截止时间，以及兑换登录后服务器下发的会话凭证。')
          this.subTitle('2. 附近组队（设备之间直接传输，不经过服务器）')
          this.bodyText('创建或加入队伍时，本应用通过蓝牙和 Wi‑Fi P2P 直连与附近设备直接通信，不经过公共路由器，也不经过开发者服务器中转或保存：')
          this.bulletText('六位加入码：队长的设备通过蓝牙广播房间信息。队员输入加入码后，会通过蓝牙把加入请求和队员昵称发给队长，以便队长确认是谁在加入。')
          this.bulletText('扫码加入：相机扫描队长二维码后，取得临时邀请信息，内容包括房间与连接参数。')
          this.bulletText('组队后：队伍成员之间会交换昵称、所选角色、节拍与场景设置、鼓机编排，以及时钟同步与音频延迟等技术参数，用于让各设备同时发声。')
          this.bulletText('建立 Wi‑Fi P2P 连接时，系统可能在确认弹窗中显示对方设备的名称。')
          this.bodyText('这些数据只在队伍存续期间使用。退出或解散队伍后，连接随即断开。')
          this.subTitle('3. 奇遇小铺：购买只在设备与华为之间完成，兑换经过开发者服务器')
          this.bodyText('购买和恢复购买由您的设备直接与华为应用内支付完成，不经过开发者服务器，也不需要登录小铺账号。只有在您使用活动口令兑换（以及同步兑换获得的权益）时，本应用才会请求华为账号登录，并与开发者服务器（位于中国香港特别行政区，详见第四部分）通信：')
          this.bulletText('华为账号（仅用于兑换）：登录后，华为账号服务返回的授权凭证（身份令牌和授权码）会发送到开发者服务器。服务器用它向华为核实账号身份，取得该账号的标识（OpenID、UnionID），用于关联您兑换获得的权益。服务器只保存 UnionID 经过不可逆处理后的值，不保存其明文；不获取您的昵称、头像、手机号、真实姓名或通讯录。服务器随后签发一个登录凭证，保存在您的设备上。')
          this.bulletText('购买与恢复购买（不经过开发者服务器）：付款通过华为应用内支付完成，本应用不接触您的银行卡或支付账户信息。本应用在您的设备上向华为查询购买结果，并校验华为的数字签名，确认无误后在设备上解锁商品、向华为确认发货。设备上会保存一份已购商品和月卡状态（有效期、是否自动续费）的摘要，供离线使用；不保存购买凭据。购买数据、订单信息和购买凭据都不会发送到开发者服务器。')
          this.bulletText('兑换码：您输入的兑换码会发送到服务器验证。服务器不保存兑换码明文，只记录兑换活动、兑换时间和对应权益的有效期。为防止恶意尝试，兑换失败时服务器会在内存中短时记录账号和网络地址（IP）的失败次数；该记录不写入数据库，服务重启后即清除。')
          this.bulletText('权益查询与记录：本应用会向服务器查询商品目录与您账号下兑换获得的权益，用于在小铺中展示和解锁功能。服务器会记录这些权益的发放、到期和撤销，用于处理兑换争议。')
          this.bulletText('服务日志：服务器的访问日志只记录请求类型、接口路径和处理耗时，不记录您的网络地址或请求内容。')
          this.bodyText('节拍练习、组队和录制不需要登录，也不会因此与开发者服务器通信。')
          this.subTitle('4. 录制行进视频')
          this.bulletText('只有在您主动开始录制，并通过系统录屏授权和麦克风授权后，本应用才会采集行进页面的画面、应用播放的声音和麦克风收到的周围声音，用于生成行进视频并显示实时声波。停止录制或离开应用后，采集结束。')
          this.bulletText('录制的视频和处理过程中产生的音频文件保存在本应用的私有目录中，不会上传。')
          this.bulletText('您点击保存后，视频会在您于系统保存弹窗中确认后存入相册。')
          this.bulletText('您点击分享后，所选视频会通过系统分享面板交给您选择的应用，后续由该应用处理。本应用不会在后台上传视频或音频。')
          this.subTitle('5. 后台播放')
          this.bodyText('为了让节拍在锁屏或切到后台时继续播放、组队连接不中断，本应用会申请后台运行，在系统媒体播控卡片中显示当前节拍信息，并在组队期间短时保持设备不休眠。这些能力不会采集额外的个人信息。')
          this.sectionTitle('二、权限使用说明')
          this.bodyText('本应用只在使用相关功能时申请以下权限。您可以随时在系统设置中关闭；关闭后，对应功能将无法使用，其他功能不受影响。')
          this.bulletText('网络访问：用于 Wi‑Fi P2P 组队通信，以及使用奇遇小铺时与开发者服务器通信。')
          this.bulletText('Wi‑Fi 信息：用于检查 Wi‑Fi 状态、发现附近设备，以及创建或加入临时 P2P 队伍。')
          this.bulletText('蓝牙：用于队长广播房间，以及队员通过六位加入码查找附近的队伍。')
          this.bulletText('相机：仅在您主动扫码加入队伍时使用。')
          this.bulletText('麦克风：仅在您主动录制行进视频时，用于收录周围声音。')
          this.bulletText('屏幕录制（系统授权弹窗）：仅在录制行进视频时，用于采集行进页画面和应用声音。')
          this.bulletText('后台运行与运行锁：用于后台继续播放节拍，并在锁屏期间保持组队连接。')
          this.bodyText('本应用不申请位置、通讯录、短信、通话记录等权限。')
          this.sectionTitle('三、数据存储与安全')
          this.bulletText('保存在设备上的信息，会在您卸载应用或清除应用数据后删除，且无法恢复。录制的视频若已保存到相册，需要在相册中自行管理。')
          this.bulletText('开发者服务器（位于中国香港特别行政区）只保存上文第一部分第 3 点所列的账号标识和兑换相关信息，不保存购买记录、节拍设置、组队数据和录制内容。这些信息会在您使用小铺服务期间持续保存，以便您换机或重装后恢复兑换获得的权益；您注销小铺账号后按第六部分处理。已购商品由华为账号保管，换机或重装后点「恢复购买」即可从华为重新取回。')
          this.bulletText('账号标识在服务器上以不可逆方式处理后保存。')
          this.bulletText('本应用与服务器之间的通信全程使用 HTTPS 加密。')
          this.bulletText('请妥善保管加入码和二维码，避免附近的陌生人加入您的队伍。')
          this.sectionTitle('四、个人信息的跨境传输')
          this.bodyText('开发者服务器位于中国香港特别行政区。您使用活动口令兑换时，第一部分第 3 点所列的账号与兑换信息会从您的设备传输到该服务器存储和处理。购买与订单信息、节拍设置、组队数据和录制内容都不会传输到该服务器。')
          this.bulletText('接收方：本应用开发者李喆，联系方式见第九部分。服务器运行在开发者租用的云服务器上。')
          this.bulletText('传输的信息：华为账号授权凭证与账号标识、兑换信息，以及兑换获得的权益记录。不包括购买与订单信息。')
          this.bulletText('目的与方式：仅用于核实账号、发放和恢复兑换获得的权益；全程通过 HTTPS 加密传输，账号标识以不可逆方式处理后保存。')
          this.bulletText('单独同意：您第一次使用活动口令兑换时，本应用会先弹窗说明上述跨境传输，征得您的单独同意后才登录华为账号。您不同意时，本应用不会向该服务器发送任何与您账号相关的信息。购买、恢复购买，以及打开小铺时用来展示商品列表的查询（不包含个人信息），都不需要此项同意。')
          this.bulletText('您的权利：您可以通过第九部分的邮箱，向接收方查询、更正或删除上述信息，也可以撤回同意。撤回同意只影响兑换，不影响购买、节拍练习、组队和录制。')
          this.sectionTitle('五、第三方服务')
          this.bodyText('本应用使用以下华为 HarmonyOS 官方服务，它们对数据的处理同时适用华为相应的隐私政策：')
          this.bulletText('华为账号服务：用于奇遇小铺的登录；')
          this.bulletText('华为应用内支付：用于购买小铺商品，并在设备上核验和恢复已购商品；')
          this.bulletText('系统分享、相册保存、录屏、媒体播控等系统能力。')
          this.bodyText('本应用不集成广告、统计分析或用户行为追踪类的第三方 SDK。')
          this.sectionTitle('六、您的权利')
          this.bulletText('管理权限：可在系统设置中随时开启或关闭本应用的各项权限。')
          this.bulletText('删除本地数据：可在应用内删除录制的作品，也可以卸载应用或清除应用数据，删除设备上的全部信息。')
          this.bulletText('取消账号授权：可在华为账号设置中取消对本应用的授权。')
          this.bulletText('在线注销小铺账号：在奇遇小铺的「我的」页面底部点击「注销小铺账号」，按提示确认即可。')
          this.bulletText('注销后兑换获得的权益再也无法找回：兑换获得的月卡立即失效，不退还、不折算。已购买的角色、场景和华为自动续费月卡不受影响，它们由华为账号保管，重装后点「恢复购买」即可找回。自动续费由华为账号管理，注销不会停止续费；如需停止，请在华为账号的订阅管理中取消。注销无法撤销。')
          this.bulletText('注销后的数据处理：服务器会删除账号与您华为账号的对应关系，并撤销兑换获得的权益。兑换记录和权益变动记录会以去标识化的形式保留，用于处理兑换争议和满足法律法规的留存要求；这些记录无法再与您的华为账号关联。服务器上没有您的购买记录。注销后用同一华为账号再次登录，会作为新账号处理。')
          this.bulletText('其他查询或删除请求：如需查询服务器上与您账号相关的信息，或无法使用在线注销，请通过下方邮箱联系我们，我们会在核实身份后 15 个工作日内处理。')
          this.sectionTitle('七、未成年人保护')
          this.bodyText('本应用以节拍练习和附近设备协作为主要内容，不主动收集可识别个人身份的信息。未成年人应在监护人指导下使用组队和购买功能。')
          this.sectionTitle('八、隐私声明的更新')
          this.bodyText('我们可能会适时更新本声明，更新后将在应用内或通过适当方式告知您。如有重大变更，我们可能会再次征求您的同意。')
          this.sectionTitle('九、联系我们')
          this.bodyText('如对本声明有任何疑问，或需要行使上述权利，请联系开发者李喆：\n邮箱：1173774897@qq.com')
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 8, bottom: 24 + this.bottomSafeInset })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAPER)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
