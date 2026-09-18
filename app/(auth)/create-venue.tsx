import { Button } from '../../components/AppButton';
import { ScrollView, View } from 'react-native';
import { router } from 'expo-router';
import { Card, Text } from 'react-native-paper';
import { authCardStyle, authColors as colors, spacing, type } from '../../lib/theme';
import { Kicker } from '../../components/AppCard';

export default function CreateVenueScreen() {
  return (
    <ScrollView style={{ flex: 1, backgroundColor: colors.background }} contentContainerStyle={{ flexGrow: 1, padding: spacing.lg, justifyContent: 'center', gap: spacing.md }}>
      <View style={{ gap: 6, alignItems: 'center' }}>
        <Kicker>Invite only</Kicker>
        <Text style={{ ...type.title, color: colors.text, textAlign: 'center' }}>Business registration is invite-only</Text>
        <Text variant="bodyMedium" style={{ color: colors.muted, textAlign: 'center' }}>
          New venues are provisioned by Venue Wrangler. If your manager invited you, continue with your invite.
        </Text>
      </View>
      <Card style={authCardStyle}>
        <Card.Content style={{ gap: spacing.sm }}>
          <Button mode="contained" buttonColor={colors.primary} textColor={colors.buttonText} onPress={() => router.replace('/(auth)/invite-check')}>
            Join with invite
          </Button>
          <Button mode="text" textColor={colors.primary} onPress={() => router.replace('/(auth)/welcome')}>
            Back
          </Button>
        </Card.Content>
      </Card>
    </ScrollView>
  );
}
