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
import AsyncStorage from '@react-native-async-storage/async-storage';

import {initLlama, releaseAllLlama} from 'llama.rn';
import {downloadModel} from './src/api/model';

const {UsageStatsModule} = NativeModules;

// Helper functions to format time
const formatTimeDetailed = (milliseconds: number) => {
  if (isNaN(milliseconds) || milliseconds < 0) return "0m 0s";
  const totalSeconds = Math.floor(milliseconds / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}m ${seconds}s`;
};

const formatTimeTotal = (milliseconds: number) => {
    if (isNaN(milliseconds) || milliseconds < 0) return "0m";
    const hours = Math.floor(milliseconds / 3600000);
    const minutes = Math.floor((milliseconds % 3600000) / 60000);
    if (hours > 0) {
        return `${hours}h ${minutes}m`;
    }
    return `${minutes}m`;
}

const BAR_WIDTH = Dimensions.get('window').width / 5;

// Custom Bar Chart Component
const CustomBarChart = ({ data, onBarPress }) => {
    const maxValue = 60; // Max minutes in an hour
    return (
        <View style={styles.chartContainer}>
            {data.map((value, index) => {
                const barHeight = Math.min(100, (value / maxValue) * 100);
                return (
                    <TouchableOpacity key={index} style={styles.barWrapper} onPress={() => onBarPress(index)}>
                        <View style={[styles.bar, { height: `${barHeight}%` }]} />
                        <Text style={styles.barLabel}>{index.toString().padStart(2, '0')}</Text>
                    </TouchableOpacity>
                );
            })}
        </View>
    );
};

function App(): React.JSX.Element {
  // Type Definitions
  type Message = { role: 'system' | 'user' | 'assistant'; content: string; timestamp: number; };
  type AppUsage = { appName: string; totalTimeInForeground: number; };
  type HourlyUsage = { hour: number; totalTime: number; apps: AppUsage[]; unlocks: number; notifications: number; };

  const INITIAL_CONVERSATION: Message[] = [
    {
      role: "system",
      content:
        "You are a helpful AI assistant. Your primary role is to answer questions based on the user's phone usage data summary that will be provided to you. Use the provided summary to answer accurately. Be concise and friendly.",
    },
  ];

  // State Variables
  const [conversation, setConversation] = useState<Message[]>(INITIAL_CONVERSATION);
  const [userInput, setUserInput] = useState('');
  const [context, setContext] = useState<any>(null);
  const [isDownloading, setIsDownloading] = useState(false);
  const [downloadProgress, setDownloadProgress] = useState(0);
  const [isGenerating, setIsGenerating] = useState(false);
  const [currentView, setCurrentView] = useState('stats');
  const [hourlyStats, setHourlyStats] = useState<HourlyUsage[]>([]);
  const [selectedHour, setSelectedHour] = useState<HourlyUsage | null>(null);
  const [isStatsLoading, setIsStatsLoading] = useState(true);
  const chartScrollViewRef = useRef<ScrollView>(null);

  const MODEL_FILENAME = "qwen2-1_5b-instruct-q4_k_m.gguf";
  const MODEL_URL = "https://huggingface.co/Qwen/Qwen2-1.5B-Instruct-GGUF/resolve/main/qwen2-1_5b-instruct-q4_k_m.gguf";

  const fetchStats = async () => {
    setIsStatsLoading(true);
    try {
      const hasPermission = await UsageStatsModule.hasUsageStatsPermission();
      if (!hasPermission) {
        Alert.alert("Permission Required", "This app needs usage stats access to grant it.", [
          { text: "Open Settings", onPress: () => UsageStatsModule.requestUsageStatsPermission() },
          { text: "Cancel", style: "cancel" },
        ]);
      } else {
        const stats: HourlyUsage[] = await UsageStatsModule.getHourlyUsageStats();
        setHourlyStats(stats);
      }
    } catch (e) {
      console.error("Error fetching hourly stats:", e);
    } finally {
      setIsStatsLoading(false);
    }
  };

  useEffect(() => {
    fetchStats();
    const subscription = AppState.addEventListener('change', (nextAppState) => {
      if (nextAppState === 'active') {
        fetchStats();
      }
    });
    return () => { subscription.remove(); };
  }, []);

  useEffect(() => {
    if (currentView === 'stats' && !isStatsLoading && hourlyStats.length > 0) {
        const currentHour = new Date().getHours();
        const scrollToX = Math.max(0, currentHour - 2) * BAR_WIDTH;
        setTimeout(() => chartScrollViewRef.current?.scrollTo({ x: scrollToX, animated: true }), 100);
    }
  }, [currentView, isStatsLoading, hourlyStats]);

  useEffect(() => {
    if (currentView === 'chat' && !context) {
        const prepareModel = async () => {
            setIsDownloading(true);
            try {
                const filePath = `${RNFS.DocumentDirectoryPath}/${MODEL_FILENAME}`;
                const fileExists = await RNFS.exists(filePath);
                if (fileExists) {
                    await loadModel(filePath);
                } else {
                    await loadModel(await downloadModel(MODEL_FILENAME, MODEL_URL, setDownloadProgress));
                }
            } catch (error) {
                Alert.alert('Model Error', error instanceof Error ? error.message : 'Unknown error.');
            } finally {
                setIsDownloading(false);
            }
        };
        prepareModel();
    } else if (currentView !== 'chat' && context) {
        releaseAllLlama();
        setContext(null);
    }
  }, [currentView]);

  const loadModel = async (filePath: string) => {
    if (context) return;
    const llamaContext = await initLlama({ model: filePath, useAssets: false, use_mlock: true, n_ctx: 2048, n_gpu_layers: 0 });
    setContext(llamaContext);
  };

  const handleSendMessage = async () => {
    if (!context || !userInput.trim()) return;

    const userMessage: Message = {role: 'user', content: userInput, timestamp: Date.now()};
    setConversation(prev => [...prev, userMessage]);
    setUserInput('');
    setIsGenerating(true);

    let messagesForAI: Message[] = [...INITIAL_CONVERSATION, ...conversation.slice(1), userMessage];

    const timeKeywords = ['time', 'hour', 'screen', 'spent', 'phone', 'usage', 'today', 'how much', 'unlock', 'notification'];
    const isTimeQuery = timeKeywords.some(keyword => userInput.toLowerCase().includes(keyword));

    if (isTimeQuery) {
        try {
            const freshHourlyStats: HourlyUsage[] = await UsageStatsModule.getHourlyUsageStats();
            setHourlyStats(freshHourlyStats);

            // --- SMART SUMMARY GENERATION ---
            const dailyTotal = freshHourlyStats.reduce((sum, hour) => sum + hour.totalTime, 0);
            const dailyUnlocks = freshHourlyStats.reduce((sum, hour) => sum + hour.unlocks, 0);
            const dailyNotifications = freshHourlyStats.reduce((sum, hour) => sum + hour.notifications, 0);
            const activeHours = freshHourlyStats.filter(h => h.totalTime > 0);
            const mostActive = activeHours.length > 0 ? activeHours.sort((a,b) => b.totalTime - a.totalTime)[0] : null;

            const appTotals = new Map<string, number>();
            freshHourlyStats.forEach(hour => {
                hour.apps.forEach(app => {
                    appTotals.set(app.appName, (appTotals.get(app.appName) || 0) + app.totalTimeInForeground);
                });
            });
            const topApps = [...appTotals.entries()].sort((a, b) => b[1] - a[1]).slice(0, 3);

            let summary = "Here is a pre-calculated summary of today's phone usage:\n";
            summary += `- Total Screen Time: ${formatTimeTotal(dailyTotal)}.\n`;
            summary += `- Total Unlocks: ${dailyUnlocks}.\n`;
            summary += `- Total Notifications: ${dailyNotifications}.\n`;
            if (mostActive) {
                summary += `- Most Active Hour: ${mostActive.hour}:00, with ${formatTimeTotal(mostActive.totalTime)} of usage, ${mostActive.unlocks} unlocks, and ${mostActive.notifications} notifications.\n`;
            }
            if (topApps.length > 0) {
                summary += `- Top Apps: ${topApps.map(([name, time]) => `${name} (${formatTimeTotal(time)})`).join(', ')}.\n`;
            }

            const contextMessage: Message = { role: 'system', content: summary, timestamp: Date.now() };
            messagesForAI.splice(messagesForAI.length - 1, 0, contextMessage);

        } catch (e) {
            console.error("Could not fetch real-time stats for AI: ", e)
        }
    }

    try {
        const result = await context.completion({messages: messagesForAI, n_predict: 400, stop: ['<|im_end|>']}, () => {});
        if (result?.text) {
            setConversation(prev => [...prev, {role: 'assistant', content: result.text.trim(), timestamp: Date.now()}]);
        }
    } catch (error) {
        Alert.alert('Generation Error', error instanceof Error ? error.message : 'Unknown error.');
    } finally {
        setIsGenerating(false);
    }
  };

  const renderChatView = () => {
    if (isDownloading || !context) {
        return (
            <View style={styles.loadingContainer}>
                <ActivityIndicator size="large" color="#2563EB" />
                <Text style={{marginTop: 10}}>
                    {isDownloading ? `Downloading Model: ${downloadProgress.toFixed(1)}%` : 'Initializing AI Model...'}
                </Text>
            </View>
        );
    }
    return (
        <>
            <ScrollView contentContainerStyle={styles.scrollViewContent}>
                <View style={styles.chatContainer}>
                    <Text style={styles.greetingText}>Model Ready.</Text>
                    {conversation.slice(1).map((msg, index) => (
                        <View key={index} style={styles.messageWrapper}>
                            <Text style={styles.timestampText}>{new Date(msg.timestamp).toLocaleTimeString([], {hour: "2-digit", minute: "2-digit"})}</Text>
                            <View style={[styles.messageBubble, msg.role === 'user' ? styles.userBubble : styles.llamaBubble]}>
                                <Text style={[styles.messageText, msg.role === 'user' && styles.userMessageText]}>{msg.content}</Text>
                            </View>
                        </View>
                    ))}
                </View>
            </ScrollView>
            <View style={styles.inputContainer}>
                <TextInput style={styles.input} placeholder="Type your message..." value={userInput} onChangeText={setUserInput} />
                <TouchableOpacity style={styles.sendButton} onPress={handleSendMessage} disabled={isGenerating}>
                    <Text style={styles.buttonText}>{isGenerating ? 'Thinking…' : 'Send'}</Text>
                </TouchableOpacity>
            </View>
        </>
    );
  };

  const renderStatsView = () => {
    if (isStatsLoading) {
        return (
            <View style={styles.loadingContainer}>
                <ActivityIndicator size="large" color="#3B82F6" />
                <Text style={{marginTop: 10, color: '#475569'}}>Loading screen time data...</Text>
            </View>
        )
    }

    const chartData = Array.from({ length: 24 }, (_, i) => {
        const statForHour = hourlyStats.find(s => s.hour === i);
        return statForHour ? statForHour.totalTime / 60000 : 0; // time in minutes
    });

    return (
        <View style={{flex: 1}}>
            <Text style={styles.sectionTitle}>Screen Time by Hour</Text>
            <View style={styles.chartHeightWrapper}>
                <ScrollView
                    horizontal
                    ref={chartScrollViewRef}
                    showsHorizontalScrollIndicator={false}
                >
                    <CustomBarChart
                        data={chartData}
                        onBarPress={(hourIndex) => {
                            const statForHour = hourlyStats.find(s => s.hour === hourIndex);
                            setSelectedHour(statForHour || null);
                        }}
                    />
                </ScrollView>
            </View>

            <ScrollView style={styles.detailsScrollView}>
                {selectedHour ? (
                    <View style={styles.hourBlock}>
                        <Text style={styles.hourTitle}>{`${selectedHour.hour.toString().padStart(2, '0')}:00`}</Text>

                        <View style={styles.statItem}>
                            <Text style={styles.summaryLabelScreenOn}>Screen On</Text>
                            <Text style={styles.summaryValueScreenOn}>{formatTimeTotal(selectedHour.totalTime)}</Text>
                        </View>

                        <View style={styles.divider} />

                        {selectedHour.apps.sort((a,b) => b.totalTimeInForeground - a.totalTimeInForeground).map((app, index) => (
                            <View key={index} style={styles.statItem}>
                            <Text style={styles.statAppName}>{app.appName}</Text>
                            <Text style={styles.statTime}>{formatTimeDetailed(app.totalTimeInForeground)}</Text>
                            </View>
                        ))}
                        <View style={styles.statItem}>
                            <Text style={styles.statAppName}>Screen Off</Text>
                            <Text style={styles.statTime}>{formatTimeDetailed(3600000 - selectedHour.totalTime)}</Text>
                        </View>

                        <View style={styles.divider} />

                        <View style={styles.statItem}>
                            <Text style={styles.summaryLabel}>Phone Unlocks</Text>
                            <Text style={styles.summaryValue}>{selectedHour.unlocks}</Text>
                        </View>
                        <View style={styles.statItem}>
                            <Text style={styles.summaryLabel}>Notifications</Text>
                            <Text style={styles.summaryValue}>{selectedHour.notifications}</Text>
                        </View>
                    </View>
                ) : (
                    <Text style={styles.placeholderText}>Tap on a bar to see details for that hour.</Text>
                )}
            </ScrollView>
      </View>
    );
  };

  return (
    <SafeAreaView style={styles.container}>
        <View style={styles.navContainer}>
            <TouchableOpacity onPress={() => setCurrentView('chat')} style={[styles.navButton, currentView === 'chat' && styles.activeNavButton]}>
                <Text style={styles.navButtonText}>Chat</Text>
            </TouchableOpacity>
            <TouchableOpacity onPress={() => setCurrentView('stats')} style={[styles.navButton, currentView === 'stats' && styles.activeNavButton]}>
                <Text style={styles.navButtonText}>Stats</Text>
            </TouchableOpacity>
        </View>
        {currentView === 'chat' ? renderChatView() : renderStatsView()}
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1, backgroundColor: '#FFFFFF'},
  loadingContainer: { flex: 1, justifyContent: 'center', alignItems: 'center' },
  navContainer: { flexDirection: 'row', justifyContent: 'space-around', paddingVertical: 10, borderBottomWidth: 1, borderBottomColor: '#E2E8F0' },
  navButton: {padding: 10, borderRadius: 8},
  activeNavButton: {backgroundColor: '#E0E7FF'},
  navButtonText: {fontSize: 16, fontWeight: '600', color: '#3B82F6'},
  scrollViewContent: {padding: 16},
  sectionTitle: { fontSize: 20, fontWeight: 'bold', color: '#1E293B', marginBottom: 16, marginTop: 10, textAlign: 'center' },

  // Chart styles
  chartHeightWrapper: { height: 220, paddingLeft: 16 },
  chartContainer: { flexDirection: 'row', height: '100%', alignItems: 'flex-end', paddingBottom: 25, },
  barWrapper: { width: BAR_WIDTH, height: '100%', alignItems: 'center', justifyContent: 'flex-end', paddingHorizontal: 10},
  bar: { width: '100%', backgroundColor: '#3B82F6', borderRadius: 4 },
  barLabel: { bottom: 0, fontSize: 14, color: '#64748B', },

  // Details styles
  detailsScrollView: { flex: 1, paddingHorizontal: 16 },
  placeholderText: { textAlign: 'center', color: '#94A3B8', marginTop: 40, fontSize: 16 },
  hourBlock: { marginTop: 24, backgroundColor: '#F8FAFC', borderRadius: 8, padding: 16, borderWidth: 1, borderColor: '#E2E8F0'},
  hourTitle: { textAlign: 'center', fontSize: 22, fontWeight: 'bold', color: '#334155', marginBottom: 12 },
  divider: { height: 1, backgroundColor: '#E2E8F0', marginVertical: 8 },
  statItem: { flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 10, paddingHorizontal: 4 },
  statAppName: {fontSize: 15, color: '#334155'},
  statTime: {fontSize: 15, fontWeight: '500', color: '#475569'},
  summaryLabel: { fontSize: 15, fontWeight: 'bold', color: '#000000' },
  summaryValue: { fontSize: 15, fontWeight: 'bold', color: '#000000' },
  summaryLabelScreenOn: { fontSize: 15, fontWeight: 'bold', color: '#3B82F6' },
  summaryValueScreenOn: { fontSize: 15, fontWeight: 'bold', color: '#3B82F6' },
  
  // Chat styles
  chatContainer: { flex: 1, backgroundColor: '#F8FAFC', borderRadius: 16, padding: 16, marginVertical: 16 },
  greetingText: { fontSize: 12, fontWeight: '500', textAlign: 'center', marginVertical: 12, color: '#64748B' },
  messageWrapper: { marginBottom: 16 },
  messageBubble: { padding: 12, borderRadius: 12, maxWidth: '80%' },
  userBubble: { alignSelf: 'flex-end', backgroundColor: '#3B82F6' },
  llamaBubble: { alignSelf: 'flex-start', backgroundColor: '#FFFFFF', borderWidth: 1, borderColor: '#E2E8F0' },
  messageText: { fontSize: 16, color: '#334155' },
  userMessageText: { color: '#FFFFFF' },
  inputContainer: { flexDirection: 'column', gap: 12, margin: 16, paddingTop: 0 },
  input: { backgroundColor: '#FFFFFF', borderWidth: 1, borderColor: '#E2E8F0', borderRadius: 12, padding: 16 },
  sendButton: { backgroundColor: '#3B82F6', paddingVertical: 14, borderRadius: 12, alignItems: 'center' },
  timestampText: { fontSize: 10, color: '#94A3B8', marginBottom: 4, marginLeft: 4 },
  buttonText: { color: '#FFFFFF', fontSize: 16, fontWeight: '600' },
});

export default App;
