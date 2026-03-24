import 'package:flutter/material.dart';

class KnowledgeScreen extends StatelessWidget {
  const KnowledgeScreen({super.key});

  static const _bg = Color(0xFFF7F3EC);
  static const _card = Color(0xFFFEFDF9);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);

  // 插畫式 Header Widget
  Widget _illustrationHeader({
    required Color color,
    required IconData mainIcon,
    required List<_DecoIcon> decos,
    required String label,
  }) {
    return Container(
      height: 156,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          // 背景大圓
          Positioned(
            right: -38,
            top: -38,
            child: Container(
              width: 130,
              height: 130,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.08),
              ),
            ),
          ),
          // 左下小圓
          Positioned(
            left: -20,
            bottom: -20,
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.06),
              ),
            ),
          ),
          // 裝飾小圖示
          ...decos.map((d) => Positioned(
                left: d.left,
                right: d.right,
                top: d.top,
                bottom: d.bottom,
                child: Icon(d.icon, size: d.size, color: color.withValues(alpha: d.opacity)),
              )),
          // 中央主圖示
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: 0.15),
                    border: Border.all(color: color.withValues(alpha: 0.2), width: 1.5),
                  ),
                  child: Icon(mainIcon, size: 44, color: color),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: color,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topics = [
      _Topic(
        category: '地震',
        color: const Color(0xFFBF7A5A),
        mainIcon: Icons.terrain_rounded,
        decos: [
          _DecoIcon(Icons.person_outline, size: 18, opacity: 0.35, left: 20, top: 20),
          _DecoIcon(Icons.home_outlined, size: 16, opacity: 0.3, right: 24, bottom: 28),
          _DecoIcon(Icons.warning_amber_rounded, size: 14, opacity: 0.25, left: 60, bottom: 18),
          _DecoIcon(Icons.compress_rounded, size: 14, opacity: 0.2, right: 60, top: 18),
        ],
        tips: [
          '保持冷靜，立即蹲下、掩護、抓穩',
          '遠離窗戶、玻璃和可能倒塌的物品',
          '如在室內，躲在桌子下或靠近承重牆',
          '不要使用電梯逃生',
          '震後注意餘震，檢查瓦斯是否外洩',
        ],
      ),
      _Topic(
        category: '颱風',
        color: const Color(0xFF6B9EAD),
        mainIcon: Icons.cyclone_rounded,
        decos: [
          _DecoIcon(Icons.cloud_outlined, size: 20, opacity: 0.35, left: 18, top: 16),
          _DecoIcon(Icons.water_drop_outlined, size: 14, opacity: 0.3, right: 22, top: 24),
          _DecoIcon(Icons.water_drop_outlined, size: 10, opacity: 0.25, right: 40, top: 40),
          _DecoIcon(Icons.air_rounded, size: 16, opacity: 0.25, left: 50, bottom: 20),
        ],
        tips: [
          '提前儲備食物、飲水和藥品',
          '關好門窗，將室外物品搬入室內',
          '遠離海岸、河川及低窪地區',
          '收聽氣象預報，遵從政府疏散指令',
          '停電時使用手電筒，避免使用蠟燭',
        ],
      ),
      _Topic(
        category: '洪水',
        color: const Color(0xFF5E8FA3),
        mainIcon: Icons.water_rounded,
        decos: [
          _DecoIcon(Icons.umbrella_outlined, size: 20, opacity: 0.35, left: 18, top: 18),
          _DecoIcon(Icons.sailing_outlined, size: 16, opacity: 0.3, right: 20, bottom: 24),
          _DecoIcon(Icons.water_drop, size: 10, opacity: 0.2, left: 55, top: 22),
          _DecoIcon(Icons.warning_rounded, size: 14, opacity: 0.2, right: 54, top: 20),
        ],
        tips: [
          '立即前往高處避難，不要等待',
          '不要嘗試徒步涉水，水流可能很急',
          '關閉電源總開關，防止觸電',
          '攜帶重要文件和緊急物資撤離',
          '等待官方宣布安全後才返回',
        ],
      ),
      _Topic(
        category: '火災',
        color: const Color(0xFFCC6B4A),
        mainIcon: Icons.local_fire_department_rounded,
        decos: [
          _DecoIcon(Icons.fire_extinguisher_outlined, size: 20, opacity: 0.35, left: 18, top: 18),
          _DecoIcon(Icons.smoke_free_rounded, size: 16, opacity: 0.28, right: 22, top: 22),
          _DecoIcon(Icons.directions_run_rounded, size: 18, opacity: 0.25, left: 54, bottom: 18),
          _DecoIcon(Icons.call, size: 14, opacity: 0.22, right: 50, bottom: 20),
        ],
        tips: [
          '立即撥打119報警',
          '低姿勢爬行，避免吸入濃煙',
          '用濕毛巾捂住口鼻',
          '不要搭乘電梯逃生，走安全梯',
          '逃出後不要回頭取物，在外等待救援',
        ],
      ),
      _Topic(
        category: '緊急物資清單',
        color: const Color(0xFF7AA67A),
        mainIcon: Icons.inventory_2_rounded,
        decos: [
          _DecoIcon(Icons.water_drop_outlined, size: 16, opacity: 0.35, left: 20, top: 18),
          _DecoIcon(Icons.flashlight_on_outlined, size: 16, opacity: 0.3, right: 22, top: 22),
          _DecoIcon(Icons.medical_services_outlined, size: 16, opacity: 0.28, left: 52, bottom: 18),
          _DecoIcon(Icons.battery_full_rounded, size: 14, opacity: 0.22, right: 50, bottom: 22),
        ],
        tips: [
          '飲用水（每人每天至少 2 公升，備 3 天份）',
          '乾糧（餅乾、罐頭等不易腐敗食物）',
          '急救藥品和個人長期用藥',
          '手電筒和備用電池',
          '重要文件影本（身分證、健保卡）',
          '備用行動電源或充電器',
          '現金（停電時電子支付可能失效）',
        ],
      ),
      _Topic(
        category: '緊急聯絡電話',
        color: const Color(0xFF9B88B3),
        mainIcon: Icons.phone_in_talk_rounded,
        decos: [
          _DecoIcon(Icons.wifi_rounded, size: 16, opacity: 0.35, left: 20, top: 18),
          _DecoIcon(Icons.battery_full_rounded, size: 14, opacity: 0.3, right: 22, top: 22),
          _DecoIcon(Icons.cell_tower_rounded, size: 16, opacity: 0.25, left: 52, bottom: 18),
          _DecoIcon(Icons.emergency_rounded, size: 18, opacity: 0.22, right: 46, bottom: 18),
        ],
        tips: [
          '緊急救援：119',
          '警察報案：110',
          '災害應變中心：1991',
          '衛生福利部安心專線：1925',
          '全國災害防救專線：0800-000-911',
        ],
      ),
    ];

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        title: const Text('防災知識'),
        centerTitle: false,
        iconTheme: const IconThemeData(color: _textPrimary),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: topics.length,
        separatorBuilder: (_, _) => const SizedBox(height: 14),
        itemBuilder: (context, index) {
          final topic = topics[index];
          final color = topic.color;
          return Container(
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF3D2C1E).withValues(alpha: 0.06),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Column(
                children: [
                  // 插畫 Header
                  _illustrationHeader(
                    color: color,
                    mainIcon: topic.mainIcon,
                    decos: topic.decos,
                    label: topic.category,
                  ),
                  // 展開式內容
                  Theme(
                    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      title: Row(
                        children: [
                          Text(
                            '${topic.tips.length} 項重點',
                            style: TextStyle(fontSize: 13, color: _textSecondary),
                          ),
                        ],
                      ),
                      iconColor: color,
                      collapsedIconColor: _textSecondary,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          child: Column(
                            children: topic.tips.asMap().entries.map((entry) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      margin: const EdgeInsets.only(top: 3),
                                      width: 20,
                                      height: 20,
                                      decoration: BoxDecoration(
                                        color: color.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Center(
                                        child: Text(
                                          '${entry.key + 1}',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: color,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        entry.value,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          color: _textPrimary,
                                          height: 1.5,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Topic {
  final String category;
  final Color color;
  final IconData mainIcon;
  final List<_DecoIcon> decos;
  final List<String> tips;

  const _Topic({
    required this.category,
    required this.color,
    required this.mainIcon,
    required this.decos,
    required this.tips,
  });
}

class _DecoIcon {
  final IconData icon;
  final double size;
  final double opacity;
  final double? left;
  final double? right;
  final double? top;
  final double? bottom;

  const _DecoIcon(
    this.icon, {
    required this.size,
    required this.opacity,
    this.left,
    this.right,
    this.top,
    this.bottom,
  });
}
