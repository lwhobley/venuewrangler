import { Button } from '../../components/AppButton';
import { useState } from 'react';
import { Alert, KeyboardAvoidingView, Platform, ScrollView, View } from 'react-native';
import { router } from 'expo-router';
import { Card, Text, TextInput } from 'react-native-paper';
import { appApi } from '../../lib/api-client';
import { authCardStyle, authColors as colors, authInputProps as inputProps, spacing, type } from '../../lib/theme';
import { Kicker } from '../../components/AppCard';
import { useAuthStore, type AuthState } from '../../lib/auth-store';

export default function WorkplaceSearchScreen() {
  const token = useAuthStore((state: AuthState) => state.token);
  const [code, setCode] = useState('');
  const [joining, setJoining] = useState(false);

  const submit = async () => {
    if (joining) return;
    const trimmed = code.trim();
    if (!trimmed) {
      Alert.alert('Join code required', 'Ask your manager for the venue join code.');
      return;
    }
    if (!token) {
      router.replace('/(auth)/sign-in');
      return;
    }
    setJoining(true);
    try {
      const result = await appApi.searchVenues(trimmed);
      const venue = result.venues[0];
      if (!venue) {
        Alert.alert('Not found', 'That join code does not match a venue.');
        return;
      }
      await appApi.submitJoinRequest({ venueId: venue.id, code: trimmed });
      router.replace('/(auth)/join-pending');
    } catch (error) {
      Alert.alert('Could not send request', error instanceof Error ? error.message : 'Try again.');
    } finally {
      setJoining(false);
    }
  };

  return (
    <KeyboardAvoidingView style={{ flex: 1, backgroundColor: colors.background }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
      <ScrollView contentContainerStyle={{ flexGrow: 1, padding: spacing.lg, justifyContent: 'center', gap: spacing.md }}>
        <View style={{ gap: 6 }}>
          <Kicker>Find your workplace</Kicker>
          <Text style={{ ...type.title, color: colors.text }}>Enter your join code</Text>
          <Text variant="bodyMedium" style={{ color: colors.muted }}>
            Venues are not listed publicly. Ask your manager for the join code.
          </Text>
        </View>
        <Card style={authCardStyle}>
          <Card.Content style={{ gap: spacing.md }}>
            <TextInput {...inputProps} label="Join code" value={code} onChangeText={setCode} autoCapitalize="characters" mode="outlined" />
            <Button mode="contained" buttonColor={colors.primary} textColor={colors.buttonText} loading={joining} disabled={joining} onPress={() => void submit()}>
              Request to join
            </Button>
            <Button mode="text" textColor={colors.primary} onPress={() => router.replace('/(auth)/invite-check')}>
              I have an email invite
            </Button>
          </Card.Content>
        </Card>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}
