import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { personApi } from '../api/person'

export function usePersons() {
  return useQuery({
    queryKey: ['persons'],
    queryFn: personApi.list,
  })
}

export function useDeletePerson() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => personApi.delete(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['persons'] }),
  })
}

export function useCreatePerson() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (params: { name: string; keywords?: string[] }) => personApi.create(params.name, params.keywords),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['persons'] }),
  })
}
