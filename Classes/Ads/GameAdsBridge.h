//
//  GameAdsBridge.h
//

#ifndef GameAdsBridge_h
#define GameAdsBridge_h

#ifdef __cplusplus
extern "C" {
#endif

/// 插屏（主界面 Play / 进关）
int GameAds_TryShowInterstitial(const char *sceneId);

/// 关卡内：右上角红色次数热区
void GameAds_ShowExtraShotHotspot(void *strengthControl);
void GameAds_HideExtraShotHotspot(void);
void GameAds_RefreshExtraShotHotspot(void);
/// Unity 屏幕坐标（左上原点）对齐 blood UI；screenW/H 为 Unity Screen 宽高
void GameAds_SetExtraShotHotspotUnityFrame(float x, float y, float w, float h, float screenW, float screenH);

/// 关卡选择：右上角设置按钮
void GameAds_ShowSettingsButton(void);
void GameAds_HideSettingsButton(void);

/// 应用音效开关到当前 GameMgr（可空）
void GameAds_ApplySoundPreference(void *gameMgr);

/// IL2CPP：激励看完后 +1 blood 并刷新 UI
void GameAds_AddExtraShot(void *strengthControl);

#ifdef __cplusplus
}
#endif

#endif
