import { useMemo, useState } from 'react';
import { ScrollView, View } from 'react-native';
import { Button, Card, Text, TextInput } from 'react-native-paper';
import { router } from 'expo-router';
import { api } from '../lib/railway-api';
import { useMutation, useQueryState } from '../lib/railway-hooks';
import { useVenueAuth } from '../lib/useVenueAuth';
import { colors, radius, spacing } from '../lib/theme';
import { ManagerGate } from '../components/ManagerGate';
import { PageHeader } from '../components/design-system';
import { ProviderDropdown } from '../components/ProviderDropdown';

type InventoryItem = { _id: string; name: string; unit: string; onHand: number; baseUnit: string; baseQuantity: number };
type RecipeLine = { itemId: string; itemName: string; quantity: number; unit: string };
type Recipe = { _id: string; name: string; ingredients: Array<RecipeLine & { stockUnit: string; baseUnit: string; baseQuantity: number }> };

function InventoryRecipesScreen() {
  const { isReady, venue, canManage, profileLoading, profileError, refetchProfile } = useVenueAuth();
  const stockState = useQueryState<{ items: InventoryItem[] }>(api.barInventory.getBarStock, isReady && venue?.id ? { venueId: venue.id } : 'skip');
  const recipesState = useQueryState<Recipe[]>(api.barInventory.listRecipes, isReady && canManage ? {} : 'skip');
  const stock = stockState.data;
  const recipes = recipesState.data;
  const saveRecipe = useMutation(api.barInventory.upsertRecipe);
  const saveConversion = useMutation(api.barInventory.updateItemConversion);
  const [name, setName] = useState('');
  const [selectedItem, setSelectedItem] = useState('');
  const [quantity, setQuantity] = useState('');
  const [unit, setUnit] = useState('');
  const [draft, setDraft] = useState<RecipeLine[]>([]);
  const [packValues, setPackValues] = useState<Record<string, { baseQuantity: string; baseUnit: string }>>({});
  const [message, setMessage] = useState('');
  const items = useMemo(() => stock?.items ?? [], [stock]);
  const selected = items.find((item) => item._id === selectedItem);

  const addIngredient = () => {
    const amount = Number(quantity);
    if (!selected || !Number.isFinite(amount) || amount <= 0 || !unit.trim()) return;
    setDraft((rows) => [...rows.filter((row) => row.itemId !== selected._id), { itemId: selected._id, itemName: selected.name, quantity: amount, unit: unit.trim() }]);
    setQuantity('');
  };

  const submitRecipe = async () => {
    if (!name.trim() || !draft.length) return;
    try {
      await saveRecipe({ name: name.trim(), ingredients: draft.map(({ itemId, quantity: qty, unit: recipeUnit }) => ({ itemId, quantity: qty, unit: recipeUnit })) });
      setName(''); setDraft([]); setMessage('Recipe saved. Future matching paid POS items will deplete stock.');
    } catch (error) { setMessage(error instanceof Error ? error.message : 'Could not save recipe.'); }
  };

  const savePack = async (item: InventoryItem) => {
    const value = packValues[item._id] ?? { baseQuantity: String(item.baseQuantity), baseUnit: item.baseUnit };
    try {
      await saveConversion({ itemId: item._id, baseQuantity: Number(value.baseQuantity), baseUnit: value.baseUnit });
      setMessage(`Pack conversion saved for ${item.name}.`);
    } catch (error) { setMessage(error instanceof Error ? error.message : 'Could not save conversion.'); }
  };

  return <ManagerGate canManage={canManage} profileLoading={profileLoading} profileError={profileError} onRetry={refetchProfile} feature="Recipe depletion">
    <ScrollView keyboardShouldPersistTaps="handled" style={{ flex: 1, backgroundColor: colors.background }} contentContainerStyle={{ padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xxl }}>
      <PageHeader kicker="Inventory" title="Recipes & conversions" detail="Map POS menu names to measured ingredient usage." />
      <Button mode="text" onPress={() => router.back()}>Back to inventory</Button>
      {(stockState.error || recipesState.error) && <Card><Card.Content><Text>Could not load all inventory data. Check your connection and try again.</Text><Button onPress={() => { void stockState.refetch(); void recipesState.refetch(); }}>Retry</Button></Card.Content></Card>}
      {(stockState.isLoading || recipesState.isLoading) && <Text>Loading inventory data…</Text>}
      {(stockState.subscriptionRequired || recipesState.subscriptionRequired) && <Text>An active subscription is required for recipe inventory.</Text>}
      <Card style={{ backgroundColor: colors.surface, borderRadius: radius.sharp }}><Card.Content style={{ gap: spacing.sm }}>
        <Text variant="titleMedium">Stock pack conversions</Text>
        <Text>Define how much recipe measure is inside one stock unit. Example: bottle · 750 · ml.</Text>
        {items.map((item) => {
          const value = packValues[item._id] ?? { baseQuantity: String(item.baseQuantity), baseUnit: item.baseUnit };
          return <View key={item._id} style={{ gap: 4, borderTopWidth: 1, borderColor: colors.border, paddingTop: spacing.sm }}>
            <Text style={{ fontWeight: '700' }}>{item.name} · stock unit: {item.unit}</Text>
            <View style={{ flexDirection: 'row', gap: spacing.sm, alignItems: 'center' }}>
              <TextInput label="Contains" value={value.baseQuantity} onChangeText={(v) => setPackValues((prev) => ({ ...prev, [item._id]: { ...value, baseQuantity: v } }))} keyboardType="decimal-pad" mode="outlined" style={{ flex: 1, backgroundColor: colors.surface }} />
              <TextInput label="Measure" value={value.baseUnit} onChangeText={(v) => setPackValues((prev) => ({ ...prev, [item._id]: { ...value, baseUnit: v } }))} autoCapitalize="none" mode="outlined" style={{ flex: 1, backgroundColor: colors.surface }} />
              <Button compact mode="outlined" onPress={() => void savePack(item)}>Save</Button>
            </View>
          </View>;
        })}
      </Card.Content></Card>
      <Card style={{ backgroundColor: colors.surface, borderRadius: radius.sharp }}><Card.Content style={{ gap: spacing.sm }}>
        <Text variant="titleMedium">POS recipe</Text>
        <Text>Recipe name must match the POS menu item name. Units convert across ml, L, fl oz, cups, tsp, tbsp, g, kg, oz weight, lb, and each.</Text>
        <TextInput label="POS menu item name" value={name} onChangeText={setName} mode="outlined" style={{ backgroundColor: colors.surface }} />
        <ProviderDropdown label="Inventory ingredient" value={selectedItem} options={items.map((item) => ({ value: item._id, label: `${item.name} (${item.unit})` }))} onChange={setSelectedItem} />
        <View style={{ flexDirection: 'row', gap: spacing.sm }}>
          <TextInput label="Amount per menu item" value={quantity} onChangeText={setQuantity} keyboardType="decimal-pad" mode="outlined" style={{ flex: 1, backgroundColor: colors.surface }} />
          <TextInput label="Recipe unit" value={unit} onChangeText={setUnit} placeholder="fl oz, g, each" autoCapitalize="none" mode="outlined" style={{ flex: 1, backgroundColor: colors.surface }} />
        </View>
        <Button mode="outlined" disabled={!selected || !quantity || !unit.trim()} onPress={addIngredient}>Add ingredient</Button>
        {draft.map((line) => <Text key={line.itemId}>{line.itemName}: {line.quantity} {line.unit} per menu item</Text>)}
        <Button mode="contained" disabled={!name.trim() || !draft.length} onPress={() => void submitRecipe()}>Save recipe</Button>
        {!!message && <Text>{message}</Text>}
      </Card.Content></Card>
      <Card style={{ backgroundColor: colors.surface, borderRadius: radius.sharp }}><Card.Content style={{ gap: spacing.sm }}>
        <Text variant="titleMedium">Configured recipes</Text>
        {(recipes ?? []).map((recipe) => <View key={recipe._id} style={{ borderTopWidth: 1, borderColor: colors.border, paddingTop: spacing.sm }}>
          <Text style={{ fontWeight: '700' }}>{recipe.name}</Text>
          {recipe.ingredients.map((line) => <Text key={line.itemId}>{line.quantity} {line.unit} {line.itemName} ({line.baseQuantity} {line.baseUnit}/{line.stockUnit})</Text>)}
        </View>)}
        {recipes && !recipes.length && <Text>No recipes configured yet.</Text>}
      </Card.Content></Card>
    </ScrollView>
  </ManagerGate>;
}

export default function InventoryRecipesRoute() { return <InventoryRecipesScreen />; }
