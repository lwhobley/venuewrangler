import { useEffect, useState } from 'react';
import { Alert, Pressable, TextInput, View } from 'react-native';
import { CommandText } from './FutureUI';
import { spacing, useDesignTheme } from '../lib/theme';
import {
  useAskWrangler,
  useWranglerOperatorExecute,
  useWranglerOperatorPlan,
  type WranglerOperatorPlan,
  type WranglerSnapshot,
} from '../lib/useWrangler';
import { formatOperatorResult } from '../lib/wrangler-result-format';


export function WranglerIntelligencePanel({
  snapshot,
  initialQuery,
  initialCommand,
}: {
  snapshot: WranglerSnapshot;
  initialQuery?: string;
  initialCommand?: string;
}) {
  const palette = useDesignTheme();
  const ask = useAskWrangler();
  const operatorPlan = useWranglerOperatorPlan();
  const operatorExecute = useWranglerOperatorExecute();
  const [question, setQuestion] = useState(initialQuery ?? '');
  const [answer, setAnswer] = useState<string | null>(null);
  const [command, setCommand] = useState(initialCommand ?? '');
  const [operatorAnswer, setOperatorAnswer] = useState<string | null>(null);
  const [pendingPlan, setPendingPlan] = useState<WranglerOperatorPlan | null>(null);
  const [pendingPreview, setPendingPreview] = useState<string[]>([]);
  const [handledInitial, setHandledInitial] = useState(false);

  useEffect(() => {
    if (handledInitial) return;
    setHandledInitial(true);
    if (initialCommand && initialCommand.trim().length >= 2) {
      void runOperator(initialCommand.trim());
    } else if (initialQuery && initialQuery.trim().length >= 2) {
      void submit(initialQuery.trim());
    }
  }, [handledInitial, initialCommand, initialQuery]);

  const submit = async (preset?: string) => {
    const value = (preset ?? question).trim();
    if (value.length < 2) return;
    const result = await ask.mutateAsync({ question: value });
    setAnswer(result.answer);
    if (preset) setQuestion(preset);
  };

  const runOperator = async (preset?: string) => {
    const value = (preset ?? command).trim();
    if (value.length < 2) return;
    setPendingPlan(null);
    setPendingPreview([]);
    try {
      const result = await operatorPlan.mutateAsync({ command: value });
      if (result.status === 'executed') {
        setOperatorAnswer(`${result.summary}\n${formatOperatorResult(result.result)}`);
      } else {
        setOperatorAnswer(result.summary);
        setPendingPlan(result.plan);
        setPendingPreview(result.preview);
      }
      if (preset) setCommand(preset);
    } catch (error) {
      setOperatorAnswer(error instanceof Error ? error.message : 'Wrangler could not process that command.');
    }
  };

  const confirmOperator = () => {
    if (!pendingPlan) return;
    const sensitive = pendingPlan.risk === 'sensitive_write';
    Alert.alert(
      sensitive ? 'Confirm sensitive operation' : 'Confirm Wrangler action',
      `${pendingPlan.summary}${pendingPreview.length ? `\n\n${pendingPreview.join('\n')}` : ''}`,
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: sensitive ? 'Confirm & record' : 'Confirm',
          style: sensitive ? 'destructive' : 'default',
          onPress: () => void (async () => {
            try {
              const result = await operatorExecute.mutateAsync({ plan: pendingPlan });
              setOperatorAnswer(`Done. ${pendingPlan.summary}\n${formatOperatorResult(result.result)}`);
              setPendingPlan(null);
              setPendingPreview([]);
            } catch (error) {
              setOperatorAnswer(error instanceof Error ? error.message : 'The operation could not be completed.');
            }
          })(),
        },
      ],
    );
  };

  return (
    <View style={{ gap: spacing.lg }}>
      <View style={{ gap: spacing.sm }}>
        <CommandText palette={palette} variant="title">Service recap</CommandText>
        <CommandText palette={palette} variant="body">{snapshot.recap.headline}</CommandText>
        {snapshot.recap.unresolved.slice(0, 3).map((item) => <CommandText key={item.id} palette={palette} variant="caption">• {item.title} — {item.reason}</CommandText>)}
      </View>

      <View style={{ gap: spacing.sm }}>
        <CommandText palette={palette} variant="title">What Wrangler is seeing</CommandText>
        {snapshot.patterns.length ? snapshot.patterns.map((pattern) => (
          <View key={pattern.id} style={{ borderTopWidth: 1, borderColor: palette.divider, paddingTop: spacing.sm, gap: 2 }}>
            <CommandText palette={palette} variant="label">{pattern.title}</CommandText>
            <CommandText palette={palette} variant="caption">{pattern.detail}</CommandText>
          </View>
        )) : <CommandText palette={palette} variant="caption">No recurring pressure is visible in the current service picture.</CommandText>}
      </View>

      <View style={{ gap: spacing.sm, borderTopWidth: 1, borderColor: palette.divider, paddingTop: spacing.lg }}>
        <CommandText palette={palette} variant="title">Wrangler Operator</CommandText>
        <CommandText palette={palette} variant="caption">Tell Wrangler what to find or change. Operational commands run and perform tasks immediately. Sensitive roster and timecard actions are previewed before execution.</CommandText>
        <View style={{ flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap' }}>
          {['Clear table 3', 'Add Jose to schedule Monday Aug 3 3pm - 12 am', '86 Tuna Tartare', 'Who is working tonight?'].map((preset) => (
            <Pressable
              accessibilityRole="button" key={preset} onPress={() => void runOperator(preset)} style={{ borderWidth: 1, borderColor: palette.border, paddingHorizontal: spacing.sm, paddingVertical: 7 }}>
              <CommandText palette={palette} variant="caption">{preset}</CommandText>
            </Pressable>
          ))}
        </View>
        <View style={{ flexDirection: 'row', gap: spacing.sm }}>
          <TextInput
            value={command}
            onChangeText={setCommand}
            placeholder="Clear table 3, 86 tuna tartare, add Jose to schedule…"
            placeholderTextColor={palette.muted}
            style={{ flex: 1, borderWidth: 1, borderColor: palette.border, backgroundColor: palette.surface, paddingHorizontal: spacing.md, paddingVertical: spacing.sm, color: palette.muted }}
            onSubmitEditing={() => void runOperator()}
          />
          <Pressable
            accessibilityRole="button" onPress={() => void runOperator()} style={{ backgroundColor: '#7A5A35', justifyContent: 'center', paddingHorizontal: spacing.md }}>
            <CommandText palette={palette} variant="label" style={{ color: '#FFFFFF' }}>{operatorPlan.isPending ? 'THINKING…' : 'RUN'}</CommandText>
          </Pressable>
        </View>
        {operatorAnswer ? <View style={{ backgroundColor: '#F8F3EA', padding: spacing.md, gap: spacing.sm }}><CommandText palette={palette} variant="body">{operatorAnswer}</CommandText>{pendingPreview.map((line) => <CommandText key={line} palette={palette} variant="caption">• {line}</CommandText>)}{pendingPlan ? <Pressable accessibilityRole="button" onPress={confirmOperator} style={{ backgroundColor: pendingPlan.risk === 'sensitive_write' ? palette.warning : '#7A5A35', paddingVertical: spacing.sm, paddingHorizontal: spacing.md, alignSelf: 'flex-start' }}><CommandText palette={palette} variant="label" style={{ color: '#FFFFFF' }}>{operatorExecute.isPending ? 'WORKING…' : pendingPlan.risk === 'sensitive_write' ? 'REVIEW & CONFIRM' : 'CONFIRM ACTION'}</CommandText></Pressable> : null}</View> : null}
      </View>

      <View style={{ gap: spacing.sm }}>
        <CommandText palette={palette} variant="title">Ask Wrangler</CommandText>
        <CommandText palette={palette} variant="caption">Ask for analysis of the live operating picture across all 9 venue domains.</CommandText>
        <View style={{ flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap' }}>
          {['What needs attention?', 'How is staffing?', 'How are sales today?'].map((preset) => (
            <Pressable
              accessibilityRole="button" key={preset} onPress={() => void submit(preset)} style={{ borderWidth: 1, borderColor: palette.border, paddingHorizontal: spacing.sm, paddingVertical: 7 }}>
              <CommandText palette={palette} variant="caption">{preset}</CommandText>
            </Pressable>
          ))}
        </View>
        <View style={{ flexDirection: 'row', gap: spacing.sm }}>
          <TextInput value={question} onChangeText={setQuestion} placeholder="Ask about tonight's service…" placeholderTextColor={palette.muted} style={{ flex: 1, borderWidth: 1, borderColor: palette.border, backgroundColor: palette.surface, paddingHorizontal: spacing.md, paddingVertical: spacing.sm, color: palette.muted }} onSubmitEditing={() => void submit()} />
          <Pressable
            accessibilityRole="button" onPress={() => void submit()} style={{ backgroundColor: '#7A5A35', justifyContent: 'center', paddingHorizontal: spacing.md }}>
            <CommandText palette={palette} variant="label" style={{ color: '#FFFFFF' }}>{ask.isPending ? 'ASKING…' : 'ASK'}</CommandText>
          </Pressable>
        </View>
        {answer ? <View style={{ backgroundColor: '#F8F3EA', padding: spacing.md }}><CommandText palette={palette} variant="body">{answer}</CommandText></View> : null}
      </View>
    </View>
  );
}
