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

      Text('更新日期：2026年10月18日')
        .fontSize(12)
        .fontColor('#6A6A6A')
        .width('100%')
        .padding({ left: 18, right: 18, top: 4 })

      Text('开发者：李喆    应用名称：OneBeat')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK)
        .width('100%')
        .padding({ left: 18, right: 18, top: 8 })

      Divider().color('#E8E2D6').margin({ top: 12, left: 18, right: 18 })

      Scroll() {
        Column({ space: 4 }) {
          this.bodyText('本应用充分尊重并保护用户隐私。请在使用前仔细阅读本声明。')

          this.sectionTitle('一、信息收集')
          this.bodyText('本应用不运营面向用户的云端账号体系，不会将您的个人信息上传至开发者服务器进行存储或分析。')
          this.bodyText('您在应用内设置的昵称、角色与节拍偏好、收藏小铺解锁状态等，均保存在您的设备本地。')
          this.bodyText('当您创建或加入队伍时，应用会通过附近设备之间的 Wi-Fi P2P 直连交换会话所需的数据（例如昵称、所选角色、节拍与场景设置、网络同步所需的技术参数）。该过程不依赖公共路由器，不经由开发者运营的远程服务器中转或长期保存。')

          this.sectionTitle('二、权限使用说明')
          this.bodyText('本应用在运行时会申请以下系统权限，均仅用于实现核心功能：')
          this.bulletText('网络访问：用于在 Wi-Fi P2P 直连通道中同步节拍与队伍状态。')
          this.bulletText('Wi‑Fi 信息：用于检查 Wi-Fi 状态、发现附近 P2P 设备并创建或加入临时 P2P 组。')
          this.bulletText('蓝牙：仅在您使用六位加入码时，用于在附近查找对应队长并取得临时邀请信息。')
          this.bulletText('相机：用于扫描队长二维码以加入队伍；仅在您主动使用扫码加入时使用。')
          this.bulletText('麦克风与屏幕录制：仅在您主动录制行进视频并授权后，采集行进画面、应用声音和周围声音，同时显示实时声波；停止录制或离开应用后结束采集。')
          this.bulletText('相册保存：仅在您点击保存视频并通过系统保存弹窗授权后，将所选视频保存到相册。')

          this.sectionTitle('三、数据存储与安全')
          this.bodyText('应用产生的设置、练习与商店相关本地状态均存储在您的设备上。除上述附近设备 P2P 组队同步外，本应用不包含将用户数据后台上传至开发者服务器的机制。')
          this.bodyText('录制视频、分享确认记录和鼓机试用截止时间保存在本机；换设备、卸载或清除应用数据不恢复。仅在您主动分享时，将选中的视频交给目标应用，并由该应用处理发布；本应用不在后台上传录音或视频。')
          this.bodyText('请妥善保管加入码与二维码，避免被附近的非预期人员加入会话。')

          this.sectionTitle('四、第三方服务')
          this.bodyText('本应用当前不集成广告、统计分析或用户行为追踪类第三方 SDK。收藏小铺为应用内本地交互，正式支付能力接入后将通过 HarmonyOS 官方支付渠道完成，届时以应用内说明及平台规则为准。')

          this.sectionTitle('五、未成年人保护')
          this.bodyText('本应用以节拍练习与附近设备协作为主要内容。我们不主动收集可识别个人身份的信息；请未成年人在监护人指导下使用网络组队功能。')

          this.sectionTitle('六、隐私声明的更新')
          this.bodyText('我们可能会适时更新本声明，更新后将在应用内或通过适当方式告知您。重大变更时，我们可能再次征求您的同意。')

          this.sectionTitle('七、联系我们')
          this.bodyText('如对本声明有任何疑问，请联系开发者：')
          this.bodyText('邮箱：1173774897@qq.com')
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
