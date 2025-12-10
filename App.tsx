import React, {useState, useEffect, useRef} from 'react';
import {
  StyleSheet,
  View,
  Alert,
  SafeAreaView,
  ScrollView,
  Text,
  TouchableOpacity,
  ActivityIndicator,
  TextInput,
  NativeModules,
  Dimensions,
  AppState,
} from 'react-native';

import RNFS from 'react-native-fs';
import {initLlama, releaseAllLlama} from 'llama.rn';
import {downloadModel} from './src/api/model';
import Icon from 'react-native-vector-icons/MaterialCommunityIcons';

const {UsageStatsModule} = NativeModules;

// --- Types ---
type Message = {
  role: 'system' | 'user' | 'assistant';
  content: string;
  timestamp: number;
};

type AppUsage = {
  appName: string;
  totalTimeInForeground: number;
};

type HourlyUsage = {
  hour: number;
  totalTime: number;
  apps: AppUsage[];
  unlocks: number;
  notifications: number;
};

// --- Helper Functions and Constants ---
const formatTimeDetailed = (milliseconds: number) => {
  if (isNaN(milliseconds) || milliseconds < 0) return '0m 0s';
  const totalSeconds = Math.floor(milliseconds / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}m ${seconds}s`;
};

const formatTimeTotal = (milliseconds: number) => {
  if (isNaN(milliseconds) || milliseconds < 0) return '0m';
  const hours = Math.floor(milliseconds / 3600000);
  const minutes = Math.floor((milliseconds % 3600000) / 60000);
  if (hours > 0) return `${hours}h ${minutes}m`;
  return `${minutes}m`;
};

const BAR_WIDTH = Dimensions.get('window').width / 5;
const NAV_ICON_SIZE = 28;
const MODEL_FILENAME = 'qwen2-1_5b-instruct-q4_k_m.gguf';
const MODEL_URL =
  'https://huggingface.co/Qwen/Qwen2-1.5B-Instruct-GGUF/resolve/main/qwen2-1_5b-instruct-q4_k_m.gguf';

const INITIAL_CONVERSATION: Message[] = [
  {
    role: 'system',
    content:
      "You are a helpful AI assistant. Your primary role is to answer questions based on the user's phone usage data summary that will be provided to you. Use the provided summary to answer accurately. Be concise and friendly.",
    timestamp: Date.now(),
  },
];

// --- Components ---
const CustomBarChart = ({
  data,
  onBarPress,
  selectedIndex = -1,
}: {
  data: number[];
  onBarPress: (index: number) => void;
  selectedIndex?: number;
}) => {
  const maxValue = 60; // max 60 minute / oră

  return (
    <View style={styles.chartContainer}>
      {data.map((value, index) => {
        const safeValue = isNaN(value) || value < 0 ? 0 : value;
        const barHeight = Math.min(90, (safeValue / maxValue) * 100); // extra headroom so the top stays rounded
        const isSelected = selectedIndex === index;
        const barColor = isSelected ? '#C9982F' : '#E3B23C';
        return (
          <TouchableOpacity
            key={index}
            style={styles.barWrapper}
            onPress={() => onBarPress(index)}>
            <View
              style={[
                styles.bar,
                {height: `${barHeight}%`, backgroundColor: barColor},
              ]}
            />
            <Text style={styles.barLabel}>
              {index.toString().padStart(2, '0')}
            </Text>
          </TouchableOpacity>
        );
      })}
    </View>
  );
};

// --- Main App Component ---
function App(): React.JSX.Element {
  // --- State Variables ---
  const [conversation, setConversation] = useState<Message[]>([]);
  const [userInput, setUserInput] = useState('');
  const [context, setContext] = useState<any>(null);
  const [isDownloading, setIsDownloading] = useState(false);
  const [downloadProgress, setDownloadProgress] = useState(0);
  const [isGenerating, setIsGenerating] = useState(false);
  const [currentView, setCurrentView] = useState<'stats' | 'chat'>('stats');
  const [hourlyStats, setHourlyStats] = useState<HourlyUsage[]>([]);
  const [selectedHour, setSelectedHour] = useState<HourlyUsage | null>(null);
  const [isStatsLoading, setIsStatsLoading] = useState(true);
  const chartScrollViewRef = useRef<ScrollView>(null);

  // --- Stats Logic ---
  const fetchStats = async () => {
    setIsStatsLoading(true);

    try {
      if (!UsageStatsModule) {
        console.warn('UsageStatsModule is undefined. Check native linking.');
        setHourlyStats([]);
        setSelectedHour(null);
        return;
      }

      const hasPermission = await UsageStatsModule.hasUsageStatsPermission();

      if (!hasPermission) {
        Alert.alert(
          'Permission Required',
          'This app needs usage stats access to work properly.',
          [
            {
              text: 'Open Settings',
              onPress: () =>
                UsageStatsModule.requestUsageStatsPermission &&
                UsageStatsModule.requestUsageStatsPermission(),
            },
            {text: 'Cancel', style: 'cancel'},
          ],
        );
        setHourlyStats([]);
        setSelectedHour(null);
      } else {
        const stats: HourlyUsage[] =
          (await UsageStatsModule.getHourlyUsageStats()) || [];
        setHourlyStats(stats);

        const currentHour = new Date().getHours();
        const currentHourStat = stats.find(s => s.hour === currentHour);
        setSelectedHour(
          currentHourStat || {
            hour: currentHour,
            apps: [],
            totalTime: 0,
            unlocks: 0,
            notifications: 0,
          },
        );
      }
    } catch (e) {
      console.error('Error fetching hourly stats:', e);
      Alert.alert(
        'Stats Error',
        e instanceof Error ? e.message : 'Failed to load usage stats.',
      );
      setHourlyStats([]);
      setSelectedHour(null);
    } finally {
      setIsStatsLoading(false);
    }
  };

  // Fetch stats on initial load and when app resumes
  useEffect(() => {
    fetchStats();
    const subscription = AppState.addEventListener('change', nextAppState => {
      if (nextAppState === 'active') {
        fetchStats();
      }
    });
    return () => {
      subscription.remove();
    };
  }, []);

  // Scroll chart to current hour when stats are loaded
  useEffect(() => {
    if (currentView === 'stats' && !isStatsLoading && hourlyStats.length > 0) {
      const currentHour = new Date().getHours();
      const scrollToX = Math.max(0, currentHour - 2) * BAR_WIDTH;
      setTimeout(
        () =>
          chartScrollViewRef.current?.scrollTo({
            x: scrollToX,
            animated: true,
          }),
        100,
      );
    }
  }, [currentView, isStatsLoading, hourlyStats]);

  // --- MODEL: load ONCE la pornirea aplicației ---
  useEffect(() => {
    let cancelled = false;

    const prepareModel = async () => {
      setIsDownloading(true);
      try {
        const filePath = `${RNFS.DocumentDirectoryPath}/${MODEL_FILENAME}`;
        const fileExists = await RNFS.exists(filePath);

        if (!fileExists) {
          await downloadModel(MODEL_FILENAME, MODEL_URL, setDownloadProgress);
        }

        if (cancelled) return;

        const llamaContext = await initLlama({
          model: filePath,
          useAssets: false,
          use_mlock: false,
        });

        if (cancelled) {
          try {
            releaseAllLlama();
          } catch {}
          return;
        }

        setContext(llamaContext);
        setConversation(INITIAL_CONVERSATION);
      } catch (error: any) {
        console.error('AI Model Error:', error);
        Alert.alert(
          'AI Model Error',
          error instanceof Error ? error.message : String(error),
        );
      } finally {
        if (!cancelled) {
          setIsDownloading(false);
        }
      }
    };

    prepareModel();

    return () => {
      cancelled = true;
      try {
        releaseAllLlama();
      } catch (e) {
        console.warn('Error releasing llama context', e);
      }
    };
  }, []);

  const handleSendMessage = async () => {
    if (!context || !userInput.trim()) return;

    const userMessage: Message = {
      role: 'user',
      content: userInput,
      timestamp: Date.now(),
    };

    setConversation(prev => [...prev, userMessage]);
    setUserInput('');
    setIsGenerating(true);

    let messagesForAI: Message[] = [...conversation, userMessage];

    const timeKeywords = [
      'time',
      'hour',
      'screen',
      'spent',
      'phone',
      'usage',
      'today',
      'how much',
      'unlock',
      'notification',
    ];
    const isTimeQuery = timeKeywords.some(keyword =>
      userInput.toLowerCase().includes(keyword),
    );

    if (isTimeQuery && UsageStatsModule) {
      try {
        const freshHourlyStats: HourlyUsage[] =
          (await UsageStatsModule.getHourlyUsageStats()) || [];
        setHourlyStats(freshHourlyStats);

        const dailyTotal = freshHourlyStats.reduce(
          (sum, hour) => sum + (hour.totalTime || 0),
          0,
        );
        const dailyUnlocks = freshHourlyStats.reduce(
          (sum, hour) => sum + (hour.unlocks || 0),
          0,
        );
        const dailyNotifications = freshHourlyStats.reduce(
          (sum, hour) => sum + (hour.notifications || 0),
          0,
        );

        const activeHours = freshHourlyStats.filter(
          h => (h.totalTime || 0) > 0,
        );
        const mostActive =
          activeHours.length > 0
            ? [...activeHours].sort(
                (a, b) => (b.totalTime || 0) - (a.totalTime || 0),
              )[0]
            : null;

        const appTotals = new Map<string, number>();
        freshHourlyStats.forEach(hour => {
          const appsArray = Array.isArray(hour.apps) ? hour.apps : [];
          appsArray.forEach(app => {
            const prev = appTotals.get(app.appName) || 0;
            appTotals.set(
              app.appName,
              prev + (app.totalTimeInForeground || 0),
            );
          });
        });

        const topApps = [...appTotals.entries()]
          .sort((a, b) => b[1] - a[1])
          .slice(0, 3);

        let summary = "Here is a pre-calculated summary of today's phone usage:\n";
        summary += `- Total Screen Time: ${formatTimeTotal(dailyTotal)}.\n`;
        summary += `- Total Unlocks: ${dailyUnlocks}.\n`;
        summary += `- Total Notifications: ${dailyNotifications}.\n`;
        if (mostActive) {
          summary += `- Most Active Hour: ${
            mostActive.hour
          }:00, with ${formatTimeTotal(
            mostActive.totalTime,
          )} of usage, ${mostActive.unlocks} unlocks, and ${
            mostActive.notifications
          } notifications.\n`;
        }
        if (topApps.length > 0) {
          summary += `- Top Apps: ${topApps
            .map(([name, time]) => `${name} (${formatTimeTotal(time)})`)
            .join(', ')}.\n`;
        }

        const contextMessage: Message = {
          role: 'system',
          content: summary,
          timestamp: Date.now(),
        };
        messagesForAI.splice(messagesForAI.length - 1, 0, contextMessage);
      } catch (e) {
        console.error('Could not fetch real-time stats for AI: ', e);
      }
    }

    try {
      const result = await context.completion(
        {
          messages: messagesForAI,
          n_predict: 400,
          stop: ['<|im_end|>'],
        },
        () => {},
      );

      if (result?.text) {
        const assistantMessage: Message = {
          role: 'assistant',
          content: result.text.trim(),
          timestamp: Date.now(),
        };
        setConversation(prev => [...prev, assistantMessage]);
      }
    } catch (error: any) {
      console.error('Generation Error:', error);
      Alert.alert(
        'Generation Error',
        error instanceof Error ? error.message : 'Unknown error.',
      );
    } finally {
      setIsGenerating(false);
    }
  };

  // --- Render Functions ---
  const renderChatView = () => {
    const showModelReady = conversation.length <= 1;

    return (
      <>
        <ScrollView contentContainerStyle={styles.scrollViewContent}>
          <View style={styles.chatContainer}>
            {showModelReady && (
              <Text style={styles.greetingText}>Model Ready.</Text>
            )}
            {conversation.slice(1).map((msg, index) => (
              <View key={index} style={styles.messageWrapper}>
                <Text style={styles.timestampText}>
                  {new Date(msg.timestamp).toLocaleTimeString([], {
                    hour: '2-digit',
                    minute: '2-digit',
                  })}
                </Text>
                <View
                  style={[
                    styles.messageBubble,
                    msg.role === 'user'
                      ? styles.userBubble
                      : styles.llamaBubble,
                  ]}>
                  <Text
                    style={[
                      styles.messageText,
                      msg.role === 'user' && styles.userMessageText,
                    ]}>
                    {msg.content}
                  </Text>
                </View>
              </View>
            ))}
          </View>
        </ScrollView>
        <View style={styles.inputContainer}>
          <TextInput
            style={styles.input}
            placeholder="Type your message..."
            value={userInput}
            onChangeText={setUserInput}
          />
          <TouchableOpacity
            style={styles.sendButton}
            onPress={handleSendMessage}
            disabled={isGenerating}>
            <Text style={styles.buttonText}>➤</Text>
          </TouchableOpacity>
        </View>
      </>
    );
  };

  const renderStatsView = () => {
    if (isStatsLoading) {
      return (
        <View style={styles.loadingContainer}>
          <ActivityIndicator size="large" />
          <Text style={{marginTop: 10, color: '#292929'}}>
            Loading screen time data...
          </Text>
        </View>
      );
    }

    const chartData = Array.from({length: 24}, (_, i) => {
      const statForHour = hourlyStats.find(s => s.hour === i);
      return statForHour ? statForHour.totalTime / 60000 : 0; // time in minutes
    });
    // Keep the current hour in view instead of starting at midnight.
    const currentHour = new Date().getHours();
    const initialScrollX = Math.max(0, currentHour - 2) * BAR_WIDTH;

    return (
      <View style={{flex: 1}}>
        <Text style={styles.sectionTitle}>Screen Time by Hour</Text>
        <View style={styles.chartHeightWrapper}>
          <ScrollView
            horizontal
            ref={chartScrollViewRef}
            contentOffset={{x: initialScrollX, y: 0}}
            showsHorizontalScrollIndicator={false}>
            <CustomBarChart
              data={chartData}
              selectedIndex={selectedHour ? selectedHour.hour : -1}
              onBarPress={hourIndex => {
                const statForHour = hourlyStats.find(s => s.hour === hourIndex);
                setSelectedHour(
                  statForHour || {
                    hour: hourIndex,
                    apps: [],
                    totalTime: 0,
                    unlocks: 0,
                    notifications: 0,
                  },
                );
              }}
            />
          </ScrollView>
        </View>

        <ScrollView style={styles.detailsScrollView}>
          {selectedHour ? (
            <View style={styles.hourBlock}>
              <Text style={styles.hourTitle}>
                {`${selectedHour.hour.toString().padStart(2, '0')}:00`}
              </Text>

              <View style={styles.statItem}>
                <Text style={styles.summaryLabel}>Screen On</Text>
                <Text style={styles.summaryValue}>
                  {formatTimeTotal(selectedHour.totalTime)}
                </Text>
              </View>

              <View style={styles.divider} />

              {(selectedHour.apps || [])
                .slice()
                .sort(
                  (a, b) =>
                    (b.totalTimeInForeground || 0) -
                    (a.totalTimeInForeground || 0),
                )
                .map((app, index) => (
                  <View key={index} style={styles.statItem1}>
                    <Text style={styles.statAppName}>{app.appName}</Text>
                    <Text style={styles.statTime}>
                      {formatTimeDetailed(app.totalTimeInForeground)}
                    </Text>
                  </View>
                ))}

              <View style={styles.divider} />
              <View style={styles.statItem}>
                <Text style={styles.summaryLabel}>Phone Unlocks</Text>
                <Text style={styles.summaryValue}>
                  {selectedHour.unlocks ?? 0}
                </Text>
              </View>
              <View style={styles.statItem}>
                <Text style={styles.summaryLabel}>Notifications</Text>
                <Text style={styles.summaryValue}>
                  {selectedHour.notifications ?? 0}
                </Text>
              </View>
            </View>
          ) : (
            <Text style={styles.placeholderText}>
              Tap on a bar to see details for that hour.
            </Text>
          )}
        </ScrollView>
      </View>
    );
  };

  // --- GLOBAL LOADING: până se încarcă și inițializează modelul ---
  if (isDownloading || !context) {
    return (
      <SafeAreaView style={styles.container}>
        <View style={styles.loadingContainer}>
          <ActivityIndicator size="large" />
          <Text style={styles.loadingText}>
            {isDownloading
              ? `Downloading Model: ${downloadProgress.toFixed(1)}%`
              : 'Initializing AI Model...'}
          </Text>
        </View>
      </SafeAreaView>
    );
  }

  // --- UI principal: Chat + Stats ---
  return (
    <SafeAreaView style={styles.container}>
      <View style={styles.contentWrapper}>
        {currentView === 'chat' ? renderChatView() : renderStatsView()}
      </View>
      <View style={styles.navContainer}>
        <TouchableOpacity
          onPress={() => setCurrentView('chat')}
          style={[
            styles.navButton,
            currentView === 'chat' && styles.activeNavButton,
          ]}>
          <Icon
            name="chat-processing-outline"
            size={NAV_ICON_SIZE}
            color={currentView === 'chat' ? '#292929' : '#FFFFFF'}
          />
        </TouchableOpacity>
        <TouchableOpacity
          onPress={() => setCurrentView('stats')}
          style={[
            styles.navButton,
            currentView === 'stats' && styles.activeNavButton,
          ]}>
          <Icon
            name="chart-bar"
            size={NAV_ICON_SIZE}
            color={currentView === 'stats' ? '#292929' : '#FFFFFF'}
          />
        </TouchableOpacity>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1, backgroundColor: '#292929'},
  contentWrapper: {flex: 1},
  loadingContainer: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: '#292929',
  },
  loadingText: {marginTop: 15, fontSize: 16, color: '#FFFFFF'},
  navContainer: {
    flexDirection: 'row',
    justifyContent: 'space-around',
    paddingVertical: 10,
    backgroundColor: '#292929',
  },
  navButton: {
    padding: 10,
    borderRadius: 8,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  activeNavButton: {backgroundColor: '#E3B23C'},
  navButtonText: {fontSize: 16, fontWeight: '600', color: '#FFFFFF'},
  activeNavButtonText: {color: '#292929'},
  scrollViewContent: {padding: 16},
  sectionTitle: {
    fontSize: 20,
    fontWeight: 'bold',
    color: '#FFFFFF',
    marginBottom: 16,
    marginTop: 10,
    textAlign: 'center',
  },

  // Chart styles
  chartHeightWrapper: {
    height: 210,
    marginHorizontal: 16,
    paddingLeft: 16,
    paddingVertical: 12,
    backgroundColor: '#292929',
    borderRadius: 12,
    borderWidth: 1,
    borderColor: '#292929',
    shadowColor: '#000000',
    shadowOpacity: 0.35,
    shadowRadius: 10,
    shadowOffset: {width: 0, height: 6},
    elevation: 6,
    },
  chartContainer: {
    flexDirection: 'row',
    height: '100%',
    alignItems: 'flex-end',
  },
  barWrapper: {
    width: BAR_WIDTH,
    height: '100%',
    justifyContent: 'flex-end',
    alignItems: 'center',
    paddingHorizontal: 10,
    paddingVertical: 5,
  },
  bar: {width: '80%', backgroundColor: '#E3B23C', borderRadius: 4},
  barLabel: {marginTop: 6, fontSize: 12, color: '#FFFFFF'},

  // Details styles
  detailsScrollView: {flex: 1, paddingHorizontal: 16},
  placeholderText: {
    textAlign: 'center',
    color: '#FFFFFF',
    marginTop: 40,
    fontSize: 16,
  },
  hourBlock: {
    marginTop: 24,
    paddingTop: 8,
  },
  hourTitle: {
    fontSize: 22,
    fontWeight: 'bold',
    color: '#FFFFFF',
    marginBottom: 12,
    textAlign: 'center',
  },
  divider: {height: 1, backgroundColor: 'rgba(255,255,255,0.2)', marginVertical: 8},
  statItem: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    paddingVertical: 10,
    paddingHorizontal: 4,
  },
  statItem1: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    paddingVertical: 10,
    paddingHorizontal: 8,
  },
  statAppName: {fontSize: 15, color: '#FFFFFF'},
  statTime: {fontSize: 15, fontWeight: '500', color: '#FFFFFF'},
  summaryLabel: {fontSize: 15, fontWeight: 'bold', color: '#FFFFFF'},
  summaryValue: {fontSize: 15, fontWeight: 'bold', color: '#FFFFFF'},

  // Chat styles
  chatContainer: {
    flex: 1,
    backgroundColor: '#292929',
    borderRadius: 16,
    padding: 16,
    marginVertical: 16,
  },
  greetingText: {
    fontSize: 12,
    fontWeight: '500',
    textAlign: 'center',
    marginVertical: 12,
    color: '#FFFFFF',
  },
  messageWrapper: {marginBottom: 16},
  messageBubble: {padding: 12, borderRadius: 12, maxWidth: '80%'},
  userBubble: {alignSelf: 'flex-end', backgroundColor: '#E3B23C'},
  llamaBubble: {
    alignSelf: 'flex-start',
    backgroundColor: '#white',
  },
  messageText: {fontSize: 16, color: '#fff'},
  userMessageText: {color: '#fff'},
  inputContainer: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    margin: 12,
    paddingTop: 0,
  },
  input: {
    flex: 1,
    backgroundColor: '#ffffff',
    borderColor: '#ffffff',
    borderRadius: 12,
    paddingHorizontal: 16,
    height: 52,
  },
  sendButton: {
    backgroundColor: '#E3B23C',
    width: 52,
    height: 52,
    borderRadius: 12,
    alignItems: 'center',
    justifyContent: 'center',
  },
  timestampText: {
    fontSize: 10,
    color: '#FFFFFF',
    marginBottom: 4,
    marginLeft: 4,
  },
  buttonText: {color: '#FFFFFF', fontSize: 16, fontWeight: '600'},
});

export default App;
