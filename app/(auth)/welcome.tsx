import { Button } from '../../components/AppButton';
import { useCallback, useEffect, useRef, useState } from 'react';
import {
  Animated,
  Dimensions,
  Platform,
  Pressable,
  StyleSheet,
  View,
  type ViewToken,
} from 'react-native';
import { router } from 'expo-router';
import { MaterialCommunityIcons } from '@expo/vector-icons';
import { Text } from 'react-native-paper';
import { authColors as colors, spacing, type } from '../../lib/theme';
import { useI18n } from '../../lib/i18n';

const { width: SCREEN_WIDTH } = Dimensions.get('window');

type Slide = {
  key: 'scheduling' | 'reservations' | 'crm';
  icon: keyof typeof MaterialCommunityIcons.glyphMap;
  secondaryIcons: (keyof typeof MaterialCommunityIcons.glyphMap)[];
};

const slides: Slide[] = [
  {
    key: 'scheduling',
    icon: 'calendar-month',
    secondaryIcons: ['clock-outline', 'account-group'],
  },
  {
    key: 'reservations',
    icon: 'book-open-variant',
    secondaryIcons: ['table-chair', 'bell-ring-outline'],
  },
  {
    key: 'crm',
    icon: 'account-heart-outline',
    secondaryIcons: ['chart-line', 'tag-multiple-outline'],
  },
];

function AnimatedSlide({
  item,
  index,
  scrollX,
  title,
  description,
  slideWidth,
}: {
  item: Slide;
  index: number;
  scrollX: Animated.Value;
  title: string;
  description: string;
  slideWidth: number;
}) {
  // Keyed to the same width the pages are laid out at, or the scale/opacity
  // interpolation drifts out of step with the scroll position.
  const inputRange = [(index - 1) * slideWidth, index * slideWidth, (index + 1) * slideWidth];

  const iconScale = scrollX.interpolate({
    inputRange,
    outputRange: [0.5, 1, 0.5],
    extrapolate: 'clamp',
  });
  const iconOpacity = scrollX.interpolate({
    inputRange,
    outputRange: [0, 1, 0],
    extrapolate: 'clamp',
  });
  const textTranslate = scrollX.interpolate({
    inputRange,
    outputRange: [40, 0, -40],
    extrapolate: 'clamp',
  });
  const textOpacity = scrollX.interpolate({
    inputRange,
    outputRange: [0, 1, 0],
    extrapolate: 'clamp',
  });

  return (
    <View style={[styles.slide, { width: slideWidth }]}>
      <Animated.View style={[styles.iconContainer, { transform: [{ scale: iconScale }], opacity: iconOpacity }]}>
        <View style={styles.iconCircle}>
          <MaterialCommunityIcons name={item.icon} size={80} color={colors.primary} />
        </View>
        <View style={styles.secondaryIcons}>
          {item.secondaryIcons.map((name, i) => (
            <View key={name} style={[styles.secondaryBadge, i === 0 ? { left: 0 } : { right: 0 }]}>
              <MaterialCommunityIcons name={name} size={28} color={colors.primary} />
            </View>
          ))}
        </View>
      </Animated.View>

      <Animated.View style={{ opacity: textOpacity, transform: [{ translateY: textTranslate }] }}>
        <Text style={styles.title}>{title}</Text>
        <Text variant="bodyLarge" style={styles.description}>{description}</Text>
      </Animated.View>
    </View>
  );
}

export default function WelcomeScreen() {
  const { t } = useI18n();
  const scrollX = useRef(new Animated.Value(0)).current;
  const flatListRef = useRef<Animated.FlatList>(null);
  const [activeIndex, setActiveIndex] = useState(0);
  // Measured rather than read from the window: on desktop web this screen
  // sits inside the content column, so the window width overshoots the list
  // viewport and every page lands off-centre.
  const [slideWidth, setSlideWidth] = useState(SCREEN_WIDTH);
  const autoPlayRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const onViewableItemsChanged = useCallback(({ viewableItems }: { viewableItems: ViewToken[] }) => {
    if (viewableItems.length > 0 && viewableItems[0].index != null) {
      setActiveIndex(viewableItems[0].index);
    }
  }, []);

  const viewabilityConfig = useRef({ viewAreaCoveragePercentThreshold: 50 }).current;

  useEffect(() => {
    autoPlayRef.current = setInterval(() => {
      setActiveIndex((prev) => {
        const next = (prev + 1) % slides.length;
        flatListRef.current?.scrollToIndex({ index: next, animated: true });
        return next;
      });
    }, 4000);
    return () => {
      if (autoPlayRef.current) clearInterval(autoPlayRef.current);
    };
  }, []);

  const stopAutoPlay = () => {
    if (autoPlayRef.current) {
      clearInterval(autoPlayRef.current);
      autoPlayRef.current = null;
    }
  };

  return (
    <View style={styles.container}>
      <View style={styles.logoArea}>
        <Text style={styles.logo}>{t('welcome.brand')}</Text>
      </View>

      <View
        style={{ flex: 1 }}
        onLayout={(event) => {
          const next = Math.round(event.nativeEvent.layout.width);
          if (next > 0 && next !== slideWidth) setSlideWidth(next);
        }}
      >
        <Animated.FlatList
          ref={flatListRef}
          data={slides}
          horizontal
          pagingEnabled
          showsHorizontalScrollIndicator={false}
          bounces={false}
          onScroll={Animated.event([{ nativeEvent: { contentOffset: { x: scrollX } } }], { useNativeDriver: true })}
          scrollEventThrottle={16}
          onViewableItemsChanged={onViewableItemsChanged}
          viewabilityConfig={viewabilityConfig}
          onScrollBeginDrag={stopAutoPlay}
          renderItem={({ item, index }: { item: Slide; index: number }) => (
            <AnimatedSlide
              item={item}
              index={index}
              scrollX={scrollX}
              slideWidth={slideWidth}
              title={t(`welcome.slides.${item.key}.title` as const)}
              description={t(`welcome.slides.${item.key}.description` as const)}
            />
          )}
          keyExtractor={(item) => item.key}
          getItemLayout={(_, index) => ({ length: slideWidth, offset: slideWidth * index, index })}
        />
      </View>

      <View style={styles.dotRow}>
        {slides.map((_, i) => (
          <Pressable
            accessibilityRole="button"
            key={i}
            onPress={() => {
              stopAutoPlay();
              flatListRef.current?.scrollToIndex({ index: i, animated: true });
            }}
          >
            <View style={[styles.dot, i === activeIndex && styles.dotActive]} />
          </Pressable>
        ))}
      </View>

      <View style={styles.buttonArea}>
        <Button
          mode="contained"
          buttonColor={colors.primary}
          textColor={colors.buttonText}
          contentStyle={styles.buttonContent}
          labelStyle={styles.buttonLabel}
          onPress={() => router.push({ pathname: '/(auth)/sign-in', params: { tab: 'signIn' } })}
        >
          {t('welcome.logIn')}
        </Button>
        <Button
          mode="outlined"
          textColor={colors.primary}
          style={styles.signUpButton}
          contentStyle={styles.buttonContent}
          labelStyle={styles.buttonLabel}
          onPress={() => router.push('/(auth)/invite-check')}
        >
          {t('welcome.joinWithInvite')}
        </Button>
        <Text style={styles.registerNote}>{t('welcome.footerNote')}</Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.background,
  },
  logoArea: {
    alignItems: 'center',
    paddingTop: Platform.OS === 'ios' ? 70 : 50,
    paddingBottom: spacing.md,
  },
  logo: {
    ...type.title,
    color: colors.primary,
  },
  slide: {
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: spacing.xl,
    gap: spacing.lg,
  },
  iconContainer: {
    alignItems: 'center',
    justifyContent: 'center',
    width: 200,
    height: 200,
  },
  iconCircle: {
    width: 160,
    height: 160,
    borderRadius: 80,
    backgroundColor: colors.highlight,
    alignItems: 'center',
    justifyContent: 'center',
  },
  secondaryIcons: {
    position: 'absolute',
    width: '100%',
    height: '100%',
  },
  secondaryBadge: {
    position: 'absolute',
    top: 10,
    width: 48,
    height: 48,
    borderRadius: 24,
    backgroundColor: colors.highlight,
    alignItems: 'center',
    justifyContent: 'center',
  },
  title: {
    ...type.heading,
    color: colors.text,
    textAlign: 'center',
    marginBottom: 8,
  },
  description: {
    color: colors.muted,
    textAlign: 'center',
    lineHeight: 22,
  },
  dotRow: {
    flexDirection: 'row',
    justifyContent: 'center',
    gap: 8,
    paddingVertical: spacing.md,
  },
  dot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: colors.border,
  },
  dotActive: {
    backgroundColor: colors.primary,
    width: 24,
  },
  buttonArea: {
    paddingHorizontal: spacing.lg,
    paddingBottom: Platform.OS === 'ios' ? 40 : 24,
    gap: 12,
  },
  buttonContent: {
    height: 52,
  },
  buttonLabel: {
    fontSize: 17,
    fontWeight: '700',
  },
  registerNote: {
    color: colors.muted,
    fontSize: 13,
    textAlign: 'center',
    marginTop: 4,
  },
  signUpButton: {
    borderColor: colors.border,
    borderWidth: 1,
  },
});
