import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/enums/ai_prompts.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/providers/ai_cache_count.dart';
import 'package:anx_reader/service/ai/ai_services.dart';
import 'package:anx_reader/service/ai/index.dart';
import 'package:anx_reader/service/ai/prompt_generate.dart';
import 'package:anx_reader/service/ai/tools/ai_tool_registry.dart';
import 'package:anx_reader/widgets/ai/ai_stream.dart';
import 'package:anx_reader/widgets/settings/settings_section.dart';
import 'package:anx_reader/widgets/settings/settings_tile.dart';
import 'package:anx_reader/widgets/settings/settings_title.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

class AISettings extends ConsumerStatefulWidget {
  const AISettings({super.key});

  @override
  ConsumerState<AISettings> createState() => _AISettingsState();
}

class _AISettingsState extends ConsumerState<AISettings> {
  bool showSettings = false;
  int currentIndex = 0;
  late List<Map<String, dynamic>> initialServicesConfig;
  bool _obscureApiKey = true;

  late final List<AiServiceOption> serviceOptions;
  late List<Map<String, dynamic>> services;

  @override
  void initState() {
    serviceOptions = buildDefaultAiServices();
    services = serviceOptions.map(
      (option) {
        return {
          'identifier': option.identifier,
          'title': option.title,
          'logo': option.logo,
          'config': {
            'url': option.defaultUrl,
            'api_key': option.defaultApiKey,
            'model': option.defaultModel,
          },
        };
      },
    ).toList();
    initialServicesConfig = services
        .map(
          (service) => {
            ...service,
            'config': Map<String, String>.from(
              service['config'] as Map<String, String>,
            ),
          },
        )
        .toList();
    for (final service in services) {
      final stored = Prefs().getAiConfig(service['identifier'] as String);
      final config = service['config'] as Map<String, String>;
      for (final entry in stored.entries) {
        config[entry.key] = entry.value;
      }
    }
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);

    List<Map<String, dynamic>> prompts = [
      {
        "identifier": AiPrompts.test,
        "title": l10n.settingsAiPromptTest,
        "variables": ["language_locale"],
      },
      {
        "identifier": AiPrompts.summaryTheChapter,
        "title": l10n.settingsAiPromptSummaryTheChapter,
        "variables": [],
      },
      {
        "identifier": AiPrompts.summaryTheBook,
        "title": l10n.settingsAiPromptSummaryTheBook,
        "variables": [],
      },
      {
        "identifier": AiPrompts.summaryThePreviousContent,
        "title": l10n.settingsAiPromptSummaryThePreviousContent,
        "variables": ["previous_content"],
      },
      {
        "identifier": AiPrompts.translate,
        "title": l10n.settingsAiPromptTranslateAndDictionary,
        "variables": ["text", "to_locale", "from_locale", "contextText"],
      },
      {
        "identifier": AiPrompts.mindmap,
        "title": l10n.settingsAiPromptMindmap,
        "variables": [],
      }
    ];

    Widget aiConfig() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              services[currentIndex]["title"],
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          for (var key in services[currentIndex]["config"].keys)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextField(
                obscureText: key == "api_key" && _obscureApiKey,
                controller: TextEditingController(
                    text: services[currentIndex]["config"][key] ??
                        initialServicesConfig[currentIndex]["config"][key]),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: key,
                  hintText: services[currentIndex]["config"][key],
                  suffixIcon: key == "api_key"
                      ? IconButton(
                          onPressed: () {
                            setState(() {
                              _obscureApiKey = !_obscureApiKey;
                            });
                          },
                          icon: _obscureApiKey
                              ? const Icon(Icons.visibility_off)
                              : const Icon(Icons.visibility),
                        )
                      : null,
                ),
                onChanged: (value) {
                  services[currentIndex]["config"][key] = value;
                },
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                  onPressed: () {
                    Prefs().deleteAiConfig(
                      services[currentIndex]["identifier"],
                    );
                    services[currentIndex]["config"] = Map<String, String>.from(
                        initialServicesConfig[currentIndex]["config"]);
                    setState(() {});
                  },
                  child: Text(L10n.of(context).commonReset)),
              TextButton(
                  onPressed: () {
                    SmartDialog.show(
                      onDismiss: () {
                        cancelActiveAiRequest();
                      },
                      builder: (context) => AlertDialog(
                          title: Text(L10n.of(context).commonTest),
                          content: AiStream(
                              prompt: generatePromptTest(),
                              identifier: services[currentIndex]["identifier"],
                              config: services[currentIndex]["config"],
                              regenerate: true)),
                    );
                  },
                  child: Text(L10n.of(context).commonTest)),
              TextButton(
                  onPressed: () {
                    Prefs().saveAiConfig(
                      services[currentIndex]["identifier"],
                      services[currentIndex]["config"],
                    );

                    setState(() {
                      showSettings = false;
                    });
                  },
                  child: Text(L10n.of(context).commonSave)),
              TextButton(
                  onPressed: () {
                    Prefs().selectedAiService =
                        services[currentIndex]["identifier"];
                    Prefs().saveAiConfig(
                      services[currentIndex]["identifier"],
                      services[currentIndex]["config"],
                    );

                    setState(() {
                      showSettings = false;
                    });
                  },
                  child: Text(L10n.of(context).commonApply)),
            ],
          )
        ],
      );
    }

    var servicesTile = CustomSettingsTile(
        child: AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 100,
              child: ListView.builder(
                shrinkWrap: true,
                scrollDirection: Axis.horizontal,
                itemCount: services.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: InkWell(
                      onTap: () {
                        if (showSettings) {
                          if (currentIndex == index) {
                            setState(() {
                              showSettings = false;
                            });
                            return;
                          }
                          showSettings = false;
                          Future.delayed(
                            const Duration(milliseconds: 200),
                            () {
                              setState(() {
                                showSettings = true;
                                currentIndex = index;
                              });
                            },
                          );
                        } else {
                          showSettings = true;
                          currentIndex = index;
                        }

                        setState(() {});
                      },
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        width: 100,
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: Prefs().selectedAiService ==
                                      services[index]["identifier"]
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.grey),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Image.asset(
                              services[index]["logo"],
                              height: 25,
                            ),
                            const SizedBox(
                              height: 10,
                            ),
                            FittedBox(child: Text(services[index]["title"])),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            !showSettings ? const SizedBox() : aiConfig(),
          ],
        ),
      ),
    ));

    var promptTile = CustomSettingsTile(
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        shrinkWrap: true,
        itemCount: prompts.length,
        itemBuilder: (context, index) {
          return SettingsTile.navigation(
            title: Text(prompts[index]["title"]),
            onPressed: (context) {
              SmartDialog.show(builder: (context) {
                final controller = TextEditingController(
                  text: Prefs().getAiPrompt(
                    AiPrompts.values[index],
                  ),
                );

                return AlertDialog(
                  title: Text(L10n.of(context).commonEdit),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        maxLines: 10,
                        controller: controller,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                        ),
                      ),
                      Wrap(
                        children: [
                          for (var variable in prompts[index]["variables"])
                            TextButton(
                              onPressed: () {
                                // insert the variables at the cursor
                                if (controller.selection.start == -1 ||
                                    controller.selection.end == -1) {
                                  return;
                                }

                                TextSelection.fromPosition(
                                  TextPosition(
                                    offset: controller.selection.start,
                                  ),
                                );

                                controller.text = controller.text.replaceRange(
                                  controller.selection.start,
                                  controller.selection.end,
                                  '{{$variable}}',
                                );
                              },
                              child: Text(
                                '{{$variable}}',
                              ),
                            ),
                        ],
                      )
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () {
                        Prefs().deleteAiPrompt(AiPrompts.values[index]);
                        controller.text = Prefs().getAiPrompt(
                          AiPrompts.values[index],
                        );
                      },
                      child: Text(L10n.of(context).commonReset),
                    ),
                    TextButton(
                      onPressed: () {
                        Prefs().saveAiPrompt(
                          AiPrompts.values[index],
                          controller.text,
                        );
                      },
                      child: Text(L10n.of(context).commonSave),
                    ),
                  ],
                );
              });
            },
          );
        },
      ),
    );

    final toolDefs = AiToolRegistry.definitions;
    final enabledToolIds = Prefs().enabledAiToolIds;

    final toolsTile = CustomSettingsTile(
      child: Column(
        children: [
          for (final tool in toolDefs)
            SettingsTile.switchTile(
              initialValue: enabledToolIds.contains(tool.id),
              onToggle: (value) {
                final next = Set<String>.from(enabledToolIds);
                if (value) {
                  next.add(tool.id);
                } else {
                  next.remove(tool.id);
                }
                Prefs().enabledAiToolIds = next.toList();
                setState(() {});
              },
              title: Text(tool.displayName(l10n)),
              description: Text(tool.description(l10n)),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () {
                Prefs().resetEnabledAiTools();
                setState(() {});
              },
              child: Text(l10n.commonReset),
            ),
          ),
        ],
      ),
    );

    return settingsSections(sections: [
      SettingsSection(
        title: Text(L10n.of(context).settingsAiServices),
        tiles: [
          servicesTile,
          // SettingsTile.navigation(
          //   leading: const Icon(Icons.chat),
          //   title: Text(L10n.of(context).aiChat),
          //   onPressed: (context) {
          //     Navigator.push(
          //       context,
          //       CupertinoPageRoute(
          //         builder: (context) => const AiChatPage(),
          //       ),
          //     );
          //   },
          // ),
        ],
      ),
      SettingsSection(
        title: Text(L10n.of(context).settingsAiPrompt),
        tiles: [
          promptTile,
        ],
      ),
      SettingsSection(
        title: Text(l10n.settingsAiTools),
        tiles: [
          toolsTile,
        ],
      ),
      SettingsSection(
        title: Text(L10n.of(context).settingsAiCache),
        tiles: [
          CustomSettingsTile(
            child: ListTile(
              title: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(L10n.of(context).settingsAiCacheSize),
                  Text(
                    L10n.of(context).settingsAiCacheCurrentSize(ref
                        .watch(aiCacheCountProvider)
                        .when(
                            data: (value) => value,
                            loading: () => 0,
                            error: (error, stack) => 0)),
                  ),
                ],
              ),
              subtitle: Row(
                children: [
                  Text(Prefs().maxAiCacheCount.toString()),
                  Expanded(
                    child: Slider(
                      value: Prefs().maxAiCacheCount.toDouble(),
                      min: 0,
                      max: 1000,
                      divisions: 100,
                      label: Prefs().maxAiCacheCount.toString(),
                      onChanged: (value) {
                        Prefs().maxAiCacheCount = value.toInt();
                        setState(() {});
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          SettingsTile.navigation(
              title: Text(L10n.of(context).settingsAiCacheClear),
              onPressed: (context) {
                SmartDialog.show(
                  builder: (context) => AlertDialog(
                    title: Text(L10n.of(context).commonConfirm),
                    actions: [
                      TextButton(
                        onPressed: () {
                          SmartDialog.dismiss();
                        },
                        child: Text(L10n.of(context).commonCancel),
                      ),
                      TextButton(
                        onPressed: () {
                          ref.read(aiCacheCountProvider.notifier).clearCache();
                          SmartDialog.dismiss();
                        },
                        child: Text(L10n.of(context).commonConfirm),
                      ),
                    ],
                  ),
                );
              }),
        ],
      ),
    ]);
  }
}
